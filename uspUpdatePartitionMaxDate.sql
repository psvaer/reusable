CREATE PROCEDURE [SSAS].[uspUpdatePartitionMaxDate]
     @ModelConfigurationID INT = NULL
    ,@ProcessingDate DATE = NULL
/******************************************************************************
* Name:		SSAS.uspUpdatePartitionMaxDate
*	
* Purpose:	Update the Max Date of the AAS Partitions to align with the Processing Date
*			       
* Example:
	exec SSAS.uspUpdatePartitionMaxDate
*******************************************************************************/
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /*
        ================================================================
        Processing date
        ================================================================
        If no processing date is supplied, use the current date in
        the configured business timezone.
    */
    SET @ProcessingDate =
        ISNULL(
            @ProcessingDate,
            CAST(
                GETDATE() AT TIME ZONE 'UTC'
                    AT TIME ZONE 'AUS Eastern Standard Time'
                AS DATE
            )
        );

    /*
        ================================================================
        Variables
        ================================================================
    */
    DECLARE
         @CurrentModelConfigurationID INT
        ,@CurrentTableConfigurationID INT
        ,@PartitioningConfigurationID INT
        ,@PartitionType VARCHAR(50)
        ,@Granularity INT
        ,@NumberOfPartitionsFull INT
        ,@NumberOfPartitionsForIncrementalProcess INT
        ,@MaxDate DATE
        ,@HasDaily BIT
        ,@HasMonthly BIT
        ,@HasYearly BIT
        ,@TargetMaxDate DATE
        ,@PeriodsAdvanced INT
        ,@NewNumberOfPartitionsFull INT
        ,@NewNumberOfPartitionsForIncrementalProcess INT
        ,@Msg VARCHAR(500);

    /*
        ================================================================
        Cursor source
        ================================================================
        Determine which granularities exist for each
        ModelConfigurationID + TableConfigurationID.
        Granularity:
            0 = Daily
            1 = Monthly
            2 = Yearly
    */
    DECLARE curAASPartitions CURSOR LOCAL FAST_FORWARD
    FOR
        WITH PartitionConfigurations AS
        (
            SELECT
                 ModelConfigurationID
                ,TableConfigurationID
                ,AnalysisServicesTable AS TableName
                ,PartitioningConfigurationID
                ,LOWER(PartitionType) AS PartitionType
                ,Granularity
                ,NumberOfPartitionsFull
                ,NumberOfPartitionsForIncrementalProcess
                ,CAST(
                    CASE
                        WHEN MaxDateIsNow = 1
                            THEN @ProcessingDate
                        ELSE MaxDate
                    END
                    AS DATE
                 ) AS MaxDate
            FROM SSAS.vPartitioningConfiguration
            WHERE DoNotProcess = 0
              AND Partitioned = 1
              AND (
                    ModelConfigurationID = @ModelConfigurationID
                    OR @ModelConfigurationID IS NULL
                  )
        ),
        ConfigurationGranularities AS
        (
            SELECT
                 ModelConfigurationID
                ,TableConfigurationID
                ,CAST(
                    MAX(
                        CASE
                            WHEN Granularity = 0 THEN 1
                            ELSE 0
                        END
                    )
                    AS BIT
                 ) AS HasDaily
                ,CAST(
                    MAX(
                        CASE
                            WHEN Granularity = 1 THEN 1
                            ELSE 0
                        END
                    )
                    AS BIT
                 ) AS HasMonthly
                ,CAST(
                    MAX(
                        CASE
                            WHEN Granularity = 2 THEN 1
                            ELSE 0
                        END
                    )
                    AS BIT
                 ) AS HasYearly
            FROM PartitionConfigurations
            GROUP BY
                 ModelConfigurationID
                ,TableConfigurationID
        )
        SELECT
             PC.ModelConfigurationID
            ,PC.TableConfigurationID
            ,PC.PartitioningConfigurationID
            ,PC.PartitionType
            ,PC.Granularity
            ,PC.NumberOfPartitionsFull
            ,PC.NumberOfPartitionsForIncrementalProcess
            ,PC.MaxDate
            ,CG.HasDaily
            ,CG.HasMonthly
            ,CG.HasYearly
        FROM PartitionConfigurations PC
        INNER JOIN ConfigurationGranularities CG
            ON  CG.ModelConfigurationID = PC.ModelConfigurationID
            AND CG.TableConfigurationID = PC.TableConfigurationID
        ORDER BY
             PC.ModelConfigurationID
            ,PC.TableConfigurationID
            ,PC.Granularity ASC;


    BEGIN TRY

        BEGIN TRANSACTION;

        OPEN curAASPartitions;

        /*
            ============================================================
            First configuration
            ============================================================
        */
        FETCH NEXT FROM curAASPartitions
        INTO
             @CurrentModelConfigurationID
            ,@CurrentTableConfigurationID
            ,@PartitioningConfigurationID
            ,@PartitionType
            ,@Granularity
            ,@NumberOfPartitionsFull
            ,@NumberOfPartitionsForIncrementalProcess
            ,@MaxDate
            ,@HasDaily
            ,@HasMonthly
            ,@HasYearly;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            /*
                ========================================================
                Validate granularity
                ========================================================
            */
            IF @Granularity NOT IN (0, 1, 2)
            BEGIN
                SET @Msg =
                    'Invalid partition granularity '
                    + ISNULL(
                        CAST(@Granularity AS VARCHAR(10)),
                        '<NULL>'
                      )
                    + ' for Partition Config ID : '
                    + CAST(@PartitioningConfigurationID AS VARCHAR(10));
                THROW 51000, @Msg, 1;
            END;

            /*
                ========================================================
                Validate partition type
                ========================================================
            */
            IF @PartitionType NOT IN ('fixed', 'expanding')
            BEGIN
                SET @Msg =
                    'Unknown Partition type : '
                    + ISNULL(@PartitionType, '<NULL>')
                    + ' for Partition Config ID : '
                    + CAST(@PartitioningConfigurationID AS VARCHAR(10));
                THROW 51000, @Msg, 1;
            END;

            /*
                ========================================================
                Calculate target MaxDate
                ========================================================
                Hierarchy:
                    Daily   : owns the current day
                    Monthly : owns the current month when Daily does not exist
                              otherwise owns completed months
                    Yearly  : owns the current year when Monthly does not exist
                              otherwise owns completed years
            */
            SET @TargetMaxDate = NULL;

            -- DAILY
            IF @Granularity = 0
            BEGIN
                /*
                    Daily owns the current processing date.
                    Example:
                        ProcessingDate = 21-Aug-2026
                        TargetMaxDate = 21-Aug-2026
                */
                SET @TargetMaxDate = @ProcessingDate;

            END

            -- MONTHLY
            ELSE IF @Granularity = 1
            BEGIN
                IF @HasDaily = 1
                BEGIN
                    /*
                        Daily owns the current month.
                        Monthly therefore owns completed months.
                        21-Aug-2026 -> 31-Jul-2026
                    */
                    SET @TargetMaxDate = EOMONTH(@ProcessingDate,-1);

                END
                ELSE
                BEGIN
                    /*
                        No Daily configuration.
                        Monthly owns the current month.
                        21-Aug-2026 -> 31-Aug-2026
                    */
                    SET @TargetMaxDate = EOMONTH(@ProcessingDate);
                END;
            END

            -- YEARLY
            ELSE IF @Granularity = 2
            BEGIN
                IF @HasMonthly = 1
                BEGIN
                    /*
                        Monthly owns the current year.
                        Yearly therefore owns completed years.
                        21-Aug-2026 -> 31-Dec-2025
                    */
                    SET @TargetMaxDate = DATEFROMPARTS(YEAR(@ProcessingDate) - 1, 12, 31);

                END
                ELSE
                BEGIN
                    /*
                        No Monthly configuration.
                        Yearly owns the current year.
                        21-Aug-2026 -> 31-Dec-2026
                    */
                    SET @TargetMaxDate = DATEFROMPARTS(YEAR(@ProcessingDate), 12, 31);
                END;
            END;

            /*
                ========================================================
                Validate target MaxDate
                ========================================================
            */
            IF @TargetMaxDate IS NULL
            BEGIN
                SET @Msg =
                    'Unable to determine target MaxDate for '
                    + 'Partition Config ID : '
                    + CAST(@PartitioningConfigurationID AS VARCHAR(10));
                THROW 51000, @Msg, 1;
            END;

            /*
                ========================================================
                Validate existing MaxDate
                ========================================================
                A NULL MaxDate is not considered a valid starting point
                because the procedure cannot determine how many periods
                an Expanding configuration has advanced.
                This also prevents a NULL value from silently bypassing
                the comparison logic.
            */
            IF @MaxDate IS NULL
            BEGIN
                SET @Msg =
                    'Partition Config ID : '
                    + CAST(@PartitioningConfigurationID AS VARCHAR(10))
                    + ' has a NULL MaxDate. '
                    + 'Partition metadata update cancelled.';

                THROW 51000, @Msg, 1;
            END;

            /*
                ========================================================
                Existing MaxDate must not be ahead of the target
                ========================================================
                Example:
                    Daily   = 21-Aug-2026
                    Monthly = 31-Jul-2026
                    Valid.
                But:
                    Daily   = 21-Aug-2026
                    Monthly = 31-Aug-2026
                    Invalid because Monthly would overlap the current month owned by Daily.
            */
            IF @MaxDate > @TargetMaxDate
            BEGIN
                SET @Msg =
                    'Partition Config ID : '
                    + CAST(@PartitioningConfigurationID AS VARCHAR(10))
                    + ' has MaxDate '
                    + CONVERT(VARCHAR(10),@MaxDate,120)
                    + ' which is beyond its calculated hierarchy '
                    + 'boundary '
                    + CONVERT(VARCHAR(10),@TargetMaxDate,120)
                    + '. Update of Partition metadata cancelled.';
                THROW 51000, @Msg, 1;
            END;

            /*
                ========================================================
                Determine whether MaxDate needs updating
                ========================================================
            */
            IF @MaxDate < @TargetMaxDate
            BEGIN
                SET @NewNumberOfPartitionsFull = @NumberOfPartitionsFull;
                SET @NewNumberOfPartitionsForIncrementalProcess = @NumberOfPartitionsForIncrementalProcess;

                /*
                    ====================================================
                    Calculate periods advanced
                    ====================================================
                    Daily:number of days
                    Monthly:number of months
                    Yearly:number of years
                */
                SET @PeriodsAdvanced =
                    CASE @Granularity
                        WHEN 0 THEN DATEDIFF(DAY, @MaxDate, @TargetMaxDate)
                        WHEN 1 THEN DATEDIFF(MONTH, @MaxDate, @TargetMaxDate)
                        WHEN 2 THEN DATEDIFF(YEAR, @MaxDate, @TargetMaxDate)
                    END;

                /*
                    ====================================================
                    Validate period advance
                    ====================================================
                */
                IF @PeriodsAdvanced IS NULL OR @PeriodsAdvanced < 0
                BEGIN
                    SET @Msg =
                        'Partition Config ID : '
                        + CAST(@PartitioningConfigurationID AS VARCHAR(10))
                        + ' calculated an invalid period advance of '
                        + ISNULL(
                            CAST(@PeriodsAdvanced AS VARCHAR(20)),
                            '<NULL>'
                          )
                        + '.';
                    THROW 51000, @Msg, 1;
                END;

                /*
                    ====================================================
                    FIXED:Fixed configurations retain the same number of partitions.
                    ====================================================                    
                */
                IF @PartitionType = 'fixed'
                BEGIN
                    SET @NewNumberOfPartitionsFull = 
                                        CASE @Granularity
                                            WHEN 0 THEN DAY(@TargetMaxDate)
                                            WHEN 1 THEN MONTH(@TargetMaxDate)
                                            WHEN 2 THEN @NumberOfPartitionsFull
                                        END;
                    SET @NewNumberOfPartitionsForIncrementalProcess = 
                                        CASE @Granularity
                                            WHEN 0 THEN IIF(DAY(@TargetMaxDate) <= 5, DAY(@TargetMaxDate), 5)                                                             
                                            ELSE @NumberOfPartitionsForIncrementalProcess
                                        END;
                END

                /*
                    ====================================================
                    EXPANDING: Every newly crossed period adds one partition.
                    ====================================================                    
                    Example:
                        Monthly
                        Current = 72 partitions
                        Jul-2026 -> Sep-2026
                        2 periods advanced
                        New = 74 partitions
                */
                ELSE IF @PartitionType = 'expanding'
                BEGIN
                    SET @NewNumberOfPartitionsFull = @NumberOfPartitionsFull + @PeriodsAdvanced;
                END;

                /*
                    ====================================================
                    Validate resulting partition count
                    ====================================================
                */
                IF @NewNumberOfPartitionsFull < 0
                BEGIN
                    SET @Msg =
                        'Partition Config ID : '
                        + CAST(@PartitioningConfigurationID AS VARCHAR(10))
                        + ' calculated an invalid '
                        + 'NumberOfPartitionsFull of '
                        + CAST(@NewNumberOfPartitionsFull AS VARCHAR(20))
                        + '.';
                    THROW 51000, @Msg, 1;
                END;

                /*
                    ====================================================
                    Update metadata
                    ====================================================
                */
                UPDATE SSAS.PartitioningConfiguration
                SET
                     MaxDate = @TargetMaxDate
                    ,NumberOfPartitionsFull = @NewNumberOfPartitionsFull
                    ,NumberOfPartitionsForIncrementalProcess = @NewNumberOfPartitionsForIncrementalProcess
                    ,ModifiedOn = GETDATE() AT TIME ZONE 'UTC' AT TIME ZONE 'AUS Eastern Standard Time'
                WHERE PartitioningConfigurationID = @PartitioningConfigurationID;
                
                -- Make sure the expected row was actually updated.              
                IF @@ROWCOUNT <> 1
                BEGIN
                    SET @Msg =
                        'Expected exactly one row to be updated for '
                        + 'Partition Config ID : '
                        + CAST( @PartitioningConfigurationID AS VARCHAR(10))
                        + '.';

                    THROW 51000, @Msg, 1;
                END;
            END;

            /*
                ========================================================
                Next configuration
                ========================================================
            */
            FETCH NEXT FROM curAASPartitions
            INTO
                 @CurrentModelConfigurationID
                ,@CurrentTableConfigurationID
                ,@PartitioningConfigurationID
                ,@PartitionType
                ,@Granularity
                ,@NumberOfPartitionsFull
                ,@NumberOfPartitionsForIncrementalProcess
                ,@MaxDate
                ,@HasDaily
                ,@HasMonthly
                ,@HasYearly;

        END;

        COMMIT TRANSACTION;

        IF CURSOR_STATUS('local', 'curAASPartitions') >= 0
        BEGIN
            CLOSE curAASPartitions;
        END;

        IF CURSOR_STATUS('local', 'curAASPartitions') >= -1
        BEGIN
            DEALLOCATE curAASPartitions;
        END;

    END TRY
    BEGIN CATCH
        
        IF XACT_STATE() <> 0
        BEGIN
            ROLLBACK TRANSACTION;
        END;

        IF CURSOR_STATUS('local', 'curAASPartitions') >= 0
        BEGIN
            CLOSE curAASPartitions;
        END;

        IF CURSOR_STATUS('local', 'curAASPartitions') >= -1
        BEGIN
            DEALLOCATE curAASPartitions;
        END;

        THROW;

    END CATCH;
END
