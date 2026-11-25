ALTER PROCEDURE [SSAS].[uspUpdatePartitionMaxDate]
     @ModelConfigurationID INT = NULL
    ,@ProcessingDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /*
        Updates the MaxDate and partition counts used by AsPartitionProcessing.

        Granularity:
            0 = Daily
            1 = Monthly
            2 = Yearly

        TableConfigurationID = 40 is a special rolling-window table:
            Daily   : first day of the month six months before the
                      processing month through the processing date.
            Monthly : 65 completed calendar months ending in the month
                      immediately before the six-month daily window.

        All other tables retain the existing Fixed / Expanding behaviour.
    */

    -- Default to the configured business timezone when no date is supplied.
    SET @ProcessingDate =
        ISNULL
        (
            @ProcessingDate,
            CAST
            (
                GETDATE() AT TIME ZONE 'UTC'
                    AT TIME ZONE 'AUS Eastern Standard Time'
                AS DATE
            )
        );

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
        ,@RollingDailyStartDate DATE
        ,@Msg VARCHAR(500);

    -- Table 40 retention settings. These are deliberately isolated here.
    DECLARE
         @SpecialTableConfigurationID INT = 40
        ,@RollingDailyMonths INT = 6
        ,@RollingMonthlyPartitions INT = 65;

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
                ,CAST
                 (
                    CASE
                        WHEN MaxDateIsNow = 1 THEN @ProcessingDate
                        ELSE MaxDate
                    END
                    AS DATE
                 ) AS MaxDate
            FROM SSAS.vPartitioningConfiguration
            WHERE DoNotProcess = 0
              AND Partitioned = 1
              AND
              (
                    ModelConfigurationID = @ModelConfigurationID
                    OR @ModelConfigurationID IS NULL
              )
        ),
        ConfigurationGranularities AS
        (
            SELECT
                 ModelConfigurationID
                ,TableConfigurationID
                ,CAST(MAX(CASE WHEN Granularity = 0 THEN 1 ELSE 0 END) AS BIT) AS HasDaily
                ,CAST(MAX(CASE WHEN Granularity = 1 THEN 1 ELSE 0 END) AS BIT) AS HasMonthly
                ,CAST(MAX(CASE WHEN Granularity = 2 THEN 1 ELSE 0 END) AS BIT) AS HasYearly
            FROM PartitionConfigurations
            GROUP BY ModelConfigurationID, TableConfigurationID
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
            ------------------------------------------------------------
            -- Validate granularity
            ------------------------------------------------------------
            IF @Granularity NOT IN (0, 1, 2)
            BEGIN
                SET @Msg =
                    'Invalid partition granularity '
                    + ISNULL(CAST(@Granularity AS VARCHAR(10)), '<NULL>')
                    + ' for Partition Config ID : '
                    + CAST(@PartitioningConfigurationID AS VARCHAR(10));
                THROW 51000, @Msg, 1;
            END;

            ------------------------------------------------------------
            -- Validate partition type. Table 40 still uses the existing
            -- Fixed / Expanding values; no new type is introduced.
            ------------------------------------------------------------
            IF @PartitionType NOT IN ('fixed', 'expanding')
            BEGIN
                SET @Msg =
                    'Unknown Partition type : '
                    + ISNULL(@PartitionType, '<NULL>')
                    + ' for Partition Config ID : '
                    + CAST(@PartitioningConfigurationID AS VARCHAR(10));
                THROW 51000, @Msg, 1;
            END;

            ------------------------------------------------------------
            -- Calculate target MaxDate
            ------------------------------------------------------------
            SET @TargetMaxDate = NULL;

            IF @CurrentTableConfigurationID = @SpecialTableConfigurationID
            BEGIN
                -- Table 40 deliberately has two adjacent rolling windows.
                SET @TargetMaxDate =
                    CASE @Granularity
                        WHEN 0 THEN @ProcessingDate
                        WHEN 1 THEN EOMONTH(@ProcessingDate, -(@RollingDailyMonths + 1))
                        ELSE NULL
                    END;
            END
            ELSE
            BEGIN
                -- Existing hierarchy logic for every other table.
                IF @Granularity = 0
                BEGIN
                    -- Daily owns the current processing date.
                    SET @TargetMaxDate = @ProcessingDate;
                END
                ELSE IF @Granularity = 1
                BEGIN
                    IF @HasDaily = 1
                    BEGIN
                        -- Monthly owns completed months when daily exists.
                        SET @TargetMaxDate = EOMONTH(@ProcessingDate, -1);
                    END
                    ELSE
                    BEGIN
                        -- Without daily, monthly owns the current month.
                        SET @TargetMaxDate = EOMONTH(@ProcessingDate);
                    END;
                END
                ELSE IF @Granularity = 2
                BEGIN
                    IF @HasMonthly = 1
                    BEGIN
                        -- Yearly owns completed years when monthly exists.
                        SET @TargetMaxDate = DATEFROMPARTS(YEAR(@ProcessingDate) - 1, 12, 31);
                    END
                    ELSE
                    BEGIN
                        -- Without monthly, yearly owns the current year.
                        SET @TargetMaxDate = DATEFROMPARTS(YEAR(@ProcessingDate), 12, 31);
                    END;
                END;
            END;

            IF @TargetMaxDate IS NULL
            BEGIN
                SET @Msg =
                    'Unable to determine target MaxDate for Partition Config ID : '
                    + CAST(@PartitioningConfigurationID AS VARCHAR(10));
                THROW 51000, @Msg, 1;
            END;

            ------------------------------------------------------------
            -- Validate existing MaxDate
            ------------------------------------------------------------
            IF @MaxDate IS NULL
            BEGIN
                SET @Msg =
                    'Partition Config ID : '
                    + CAST(@PartitioningConfigurationID AS VARCHAR(10))
                    + ' has a NULL MaxDate. Partition metadata update cancelled.';
                THROW 51000, @Msg, 1;
            END;

            /*
                For normal tables, retain the original hierarchy validation.
                Table 40 is intentionally different: its monthly MaxDate is
                expected to move backwards from the old hierarchy boundary
                (31-Oct-2026) to the rolling-window boundary (30-Apr-2026).
            */
            IF @CurrentTableConfigurationID <> @SpecialTableConfigurationID
               AND @MaxDate > @TargetMaxDate
            BEGIN
                SET @Msg =
                    'Partition Config ID : '
                    + CAST(@PartitioningConfigurationID AS VARCHAR(10))
                    + ' has MaxDate '
                    + CONVERT(VARCHAR(10), @MaxDate, 120)
                    + ' which is beyond its calculated hierarchy boundary '
                    + CONVERT(VARCHAR(10), @TargetMaxDate, 120)
                    + '. Update of Partition metadata cancelled.';
                THROW 51000, @Msg, 1;
            END;

            ------------------------------------------------------------
            -- Determine whether metadata needs updating
            ------------------------------------------------------------
            SET @NewNumberOfPartitionsFull = @NumberOfPartitionsFull;
            SET @NewNumberOfPartitionsForIncrementalProcess =
                @NumberOfPartitionsForIncrementalProcess;

            IF @CurrentTableConfigurationID = @SpecialTableConfigurationID
            BEGIN
                --------------------------------------------------------
                -- Table 40: fixed rolling windows, independent of the
                -- current calendar day/month and independent of the
                -- configured Fixed / Expanding value.
                --------------------------------------------------------
                IF @Granularity = 0
                BEGIN
                    -- First day of the month six months before the
                    -- processing month, through the processing date.
                    SET @RollingDailyStartDate =
                        DATEFROMPARTS
                        (
                            YEAR(DATEADD(MONTH, -@RollingDailyMonths, @ProcessingDate)),
                            MONTH(DATEADD(MONTH, -@RollingDailyMonths, @ProcessingDate)),
                            1
                        );

                    SET @NewNumberOfPartitionsFull =
                        DATEDIFF(DAY, @RollingDailyStartDate, @TargetMaxDate) + 1;
                END
                ELSE IF @Granularity = 1
                BEGIN
                    -- 65 complete calendar months ending at TargetMaxDate.
                    SET @NewNumberOfPartitionsFull = @RollingMonthlyPartitions;
                END
                ELSE
                BEGIN
                    SET @Msg =
                        'TableConfigurationID 40 supports only Daily (0) '
                        + 'and Monthly (1) granularities. Partition Config ID : '
                        + CAST(@PartitioningConfigurationID AS VARCHAR(10));
                    THROW 51000, @Msg, 1;
                END;

                -- Keep the configured incremental/hot partition counts (5 daily, 2 monthly).
                SET @NewNumberOfPartitionsForIncrementalProcess =
                    @NumberOfPartitionsForIncrementalProcess;

                -- Unlike the original forward-only logic, update when the
                -- date moves either direction or when the rolling count changes.
                IF @MaxDate <> @TargetMaxDate
                   OR @NumberOfPartitionsFull <> @NewNumberOfPartitionsFull
                BEGIN
                    UPDATE SSAS.PartitioningConfiguration
                    SET
                         MaxDate = @TargetMaxDate
                        ,NumberOfPartitionsFull = @NewNumberOfPartitionsFull
                        ,NumberOfPartitionsForIncrementalProcess = @NewNumberOfPartitionsForIncrementalProcess
                        ,ModifiedOn = GETDATE() AT TIME ZONE 'UTC' AT TIME ZONE 'AUS Eastern Standard Time'
                    WHERE PartitioningConfigurationID = @PartitioningConfigurationID;

                    IF @@ROWCOUNT <> 1
                    BEGIN
                        SET @Msg =
                            'Expected exactly one row to be updated for Partition Config ID : '
                            + CAST(@PartitioningConfigurationID AS VARCHAR(10)) + '.';
                        THROW 51000, @Msg, 1;
                    END;
                END;
            END
            ELSE IF @MaxDate < @TargetMaxDate
            BEGIN
                --------------------------------------------------------
                -- Existing behaviour for all tables other than Table 40
                --------------------------------------------------------
                SET @PeriodsAdvanced =
                    CASE @Granularity
                        WHEN 0 THEN DATEDIFF(DAY, @MaxDate, @TargetMaxDate)
                        WHEN 1 THEN DATEDIFF(MONTH, @MaxDate, @TargetMaxDate)
                        WHEN 2 THEN DATEDIFF(YEAR, @MaxDate, @TargetMaxDate)
                    END;

                IF @PeriodsAdvanced IS NULL OR @PeriodsAdvanced < 0
                BEGIN
                    SET @Msg =
                        'Partition Config ID : '
                        + CAST(@PartitioningConfigurationID AS VARCHAR(10))
                        + ' calculated an invalid period advance of '
                        + ISNULL(CAST(@PeriodsAdvanced AS VARCHAR(20)), '<NULL>')
                        + '.';
                    THROW 51000, @Msg, 1;
                END;

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
                ELSE IF @PartitionType = 'expanding'
                BEGIN
                    SET @NewNumberOfPartitionsFull =
                        @NumberOfPartitionsFull + @PeriodsAdvanced;
                END;

                IF @NewNumberOfPartitionsFull < 0
                BEGIN
                    SET @Msg =
                        'Partition Config ID : '
                        + CAST(@PartitioningConfigurationID AS VARCHAR(10))
                        + ' calculated an invalid NumberOfPartitionsFull of '
                        + CAST(@NewNumberOfPartitionsFull AS VARCHAR(20))
                        + '.';
                    THROW 51000, @Msg, 1;
                END;

                UPDATE SSAS.PartitioningConfiguration
                SET
                     MaxDate = @TargetMaxDate
                    ,NumberOfPartitionsFull = @NewNumberOfPartitionsFull
                    ,NumberOfPartitionsForIncrementalProcess = @NewNumberOfPartitionsForIncrementalProcess
                    ,ModifiedOn = GETDATE() AT TIME ZONE 'UTC' AT TIME ZONE 'AUS Eastern Standard Time'
                WHERE PartitioningConfigurationID = @PartitioningConfigurationID;

                IF @@ROWCOUNT <> 1
                BEGIN
                    SET @Msg =
                        'Expected exactly one row to be updated for Partition Config ID : '
                        + CAST(@PartitioningConfigurationID AS VARCHAR(10)) + '.';
                    THROW 51000, @Msg, 1;
                END;
            END;

            ------------------------------------------------------------
            -- Next configuration
            ------------------------------------------------------------
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

        CLOSE curAASPartitions;
        DEALLOCATE curAASPartitions;

        COMMIT TRANSACTION;
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
END;
GO
