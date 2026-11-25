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

        Offset is an optional number of granularity periods to move the
        target MaxDate backwards from the processing date.

        For a daily + monthly hierarchy, a positive monthly Offset also
        defines the daily rolling window: Offset - 1 calendar months.
        Example: monthly Offset = 7 gives six calendar months of daily
        partitions, followed by monthly partitions ending in the prior month.

        Existing configurations use Offset = 0 and retain their existing
        Fixed / Expanding behaviour.
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
        ,@Offset INT
        ,@MonthlyOffset INT
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
        ,@RollingDailyMonths INT
        ,@Msg VARCHAR(500);

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
                ,ISNULL([Offset], 0) AS [Offset]
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
                ,MAX(CASE WHEN Granularity = 1 THEN [Offset] END) AS MonthlyOffset
            FROM PartitionConfigurations
            GROUP BY ModelConfigurationID, TableConfigurationID
        )
        SELECT
             PC.ModelConfigurationID
            ,PC.TableConfigurationID
            ,PC.PartitioningConfigurationID
            ,PC.PartitionType
            ,PC.Granularity
            ,PC.[Offset]
            ,PC.NumberOfPartitionsFull
            ,PC.NumberOfPartitionsForIncrementalProcess
            ,PC.MaxDate
            ,CG.HasDaily
            ,CG.HasMonthly
            ,CG.HasYearly
            ,ISNULL(CG.MonthlyOffset, 0) AS MonthlyOffset
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
            ,@Offset
            ,@NumberOfPartitionsFull
            ,@NumberOfPartitionsForIncrementalProcess
            ,@MaxDate
            ,@HasDaily
            ,@HasMonthly
            ,@HasYearly
            ,@MonthlyOffset;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            ------------------------------------------------------------
            -- Validate granularity
            ------------------------------------------------------------
            IF @Offset < 0
            BEGIN
                SET @Msg =
                    'Offset cannot be negative for Partition Config ID : '
                    + CAST(@PartitioningConfigurationID AS VARCHAR(10));
                THROW 51000, @Msg, 1;
            END;

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
            -- Validate partition type. Offset does not introduce a new
            -- partition type; the existing Fixed / Expanding values remain valid.
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

            IF @Offset > 0
            BEGIN
                -- A positive Offset explicitly positions this granularity
                -- relative to the processing date.
                SET @TargetMaxDate =
                    CASE @Granularity
                        WHEN 0 THEN DATEADD(DAY, -@Offset, @ProcessingDate)
                        WHEN 1 THEN EOMONTH(@ProcessingDate, -@Offset)
                        WHEN 2 THEN DATEFROMPARTS(YEAR(@ProcessingDate) - @Offset, 12, 31)
                        ELSE NULL
                    END;
            END
            ELSE
            BEGIN
                -- Offset = 0 retains the existing hierarchy behaviour.
                IF @Granularity = 0
                BEGIN
                    SET @TargetMaxDate = @ProcessingDate;
                END
                ELSE IF @Granularity = 1
                BEGIN
                    IF @HasDaily = 1
                        SET @TargetMaxDate = EOMONTH(@ProcessingDate, -1);
                    ELSE
                        SET @TargetMaxDate = EOMONTH(@ProcessingDate);
                END
                ELSE IF @Granularity = 2
                BEGIN
                    IF @HasMonthly = 1
                        SET @TargetMaxDate = DATEFROMPARTS(YEAR(@ProcessingDate) - 1, 12, 31);
                    ELSE
                        SET @TargetMaxDate = DATEFROMPARTS(YEAR(@ProcessingDate), 12, 31);
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

            -- A positive Offset can intentionally move MaxDate backwards.
            IF @Offset = 0
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

            /*
                Rolling-window handling is metadata-driven:
                  - A positive Offset keeps the configured partition count
                    and moves the upper boundary as required.
                  - For a daily + monthly hierarchy, MonthlyOffset - 1 is
                    the number of calendar months retained at daily grain.
                    This keeps the daily and monthly ranges contiguous.

                NumberOfPartitionsFull remains the configured retention count
                for monthly and other offset-based granularities. Daily count
                is recalculated because the number of days in six calendar
                months varies with the processing date.
            */
            IF @Offset > 0 OR (@Granularity = 0 AND @MonthlyOffset > 1)
            BEGIN
                IF @Granularity = 0 AND @MonthlyOffset > 1
                BEGIN
                    SET @RollingDailyMonths = @MonthlyOffset - 1;
                    SET @RollingDailyStartDate =
                        DATEFROMPARTS
                        (
                            YEAR(DATEADD(MONTH, -@RollingDailyMonths, @ProcessingDate)),
                            MONTH(DATEADD(MONTH, -@RollingDailyMonths, @ProcessingDate)),
                            1
                        );

                    SET @NewNumberOfPartitionsFull =
                        DATEDIFF(DAY, @RollingDailyStartDate, @TargetMaxDate) + 1;
                END;

                -- Keep the configured incremental partition count unchanged.
                SET @NewNumberOfPartitionsForIncrementalProcess =
                    @NumberOfPartitionsForIncrementalProcess;

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
                -- Existing behaviour for configurations without rolling offsets
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
                ,@Offset
                ,@NumberOfPartitionsFull
                ,@NumberOfPartitionsForIncrementalProcess
                ,@MaxDate
                ,@HasDaily
                ,@HasMonthly
                ,@HasYearly
            ,@MonthlyOffset;
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
