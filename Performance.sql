-- Purpose of the code: This stored procedure retrieves performance-related information for sales employees, territories, and years.
-- It incorporates transactions to ensure data consistency.

-- Input Parameters:
-- @SelectedYear: Filter the results for a specific year. If NULL, results for all years are considered.

CREATE PROCEDURE spPerformance
    @SelectedYear INT = NULL
AS
BEGIN

    -- Begin the outermost transaction
    BEGIN TRANSACTION OuterTransaction;

    BEGIN TRY
        -- First Query Transaction: Retrieve detailed performance information for sales employees, territories, and products
        BEGIN TRANSACTION FirstQueryTransaction;

        -- First Query: Populate a temporary table with detailed sales performance data to use easily
        SELECT DISTINCT
            h.SalesPersonID,
            p.FirstName,
            p.LastName,
            e.HireDate,
            d.LineTotal,
            d.OrderQty,
            pp.StandardCost,
            YEAR(h.OrderDate) AS year_sale,
            (d.LineTotal - (pp.StandardCost * d.OrderQty)) AS Profit,
            (d.LineTotal / NULLIF(d.OrderQty, 0) - pp.StandardCost) AS UnitProfit, -- Avoid division by zero
            t.[Name] AS Territory,
            c.CustomerID,
            s.SalesQuota
        INTO #panel_TestEmployee43
        FROM sales.SalesOrderHeader h
        JOIN Sales.SalesOrderDetail d ON h.SalesOrderID = d.SalesOrderID
        JOIN Production.Product pp ON d.ProductID = pp.ProductID
        JOIN HumanResources.Employee e ON e.BusinessEntityID = h.SalesPersonID
        JOIN Person.Person p ON e.BusinessEntityID = p.BusinessEntityID
        JOIN sales.SalesPerson s ON p.BusinessEntityID = s.BusinessEntityID
        JOIN Sales.Customer c ON h.CustomerID = c.CustomerID
        JOIN Sales.SalesTerritory t ON c.TerritoryID = t.TerritoryID
        WHERE (@SelectedYear IS NULL OR YEAR(h.OrderDate) = @SelectedYear);

        -- Commit the First Query Transaction
        IF @@TRANCOUNT > 0
            COMMIT TRANSACTION FirstQueryTransaction;

        -- Calculate the average total profit for further analysis
        DECLARE @AvgTotalProfit DECIMAL(18, 2);
        SELECT @AvgTotalProfit = AVG(TotalProfit)
        FROM (
            SELECT SUM(Profit) AS TotalProfit
            FROM #panel_TestEmployee43
            WHERE UnitProfit > 0
            GROUP BY SalesPersonID
        ) AS AvgProfitTable;

        -- Second Query Transaction: Analyze the sales performance and categorize employees
        BEGIN TRANSACTION SecondQueryTransaction;

        -- Second Query: Retrieve summarized performance information with employee categories
        SELECT
            p.SalesPersonID,
            p.FirstName,
            p.LastName,
            p.TotalProfit,
            p.AverageProfitPerEmployeeSales,
            p.Rank,
            p.Category,
            p.Commission,
            p.Bonus,
            t1.TerritoryWithMostProfit,
            t1.CustomerCountForTerritoryWithMostProfit
        FROM (
            SELECT
                SalesPersonID,
                FirstName,
                LastName,
                SUM(Profit) AS TotalProfit,
                AVG(Profit) AS AverageProfitPerEmployeeSales,
                RANK() OVER (ORDER BY SUM(Profit) DESC) AS Rank,
                CASE
                    WHEN SUM(Profit) > (@AvgTotalProfit * 2) THEN 'Vital Employee'
                    WHEN SUM(Profit) >= @AvgTotalProfit THEN 'Valuable Employee'
                    ELSE 'Requires More Sales Training'
                END AS Category,
                CASE
                    WHEN SUM(Profit) > (@AvgTotalProfit * 2) THEN '8%'
                    WHEN SUM(Profit) >= @AvgTotalProfit THEN '5%'
                    ELSE '3%'
                END AS Commission,
                CASE
                    WHEN SUM(Profit) > (@AvgTotalProfit * 2) THEN SUM(Profit) * 0.08
                    WHEN SUM(Profit) >= @AvgTotalProfit THEN SUM(Profit) * 0.05
                    ELSE SUM(Profit) * 0.03
                END AS Bonus
            FROM #panel_TestEmployee43
            WHERE UnitProfit > 0
            GROUP BY SalesPersonID, FirstName, LastName
        ) AS p
        JOIN (
            SELECT
                SalesPersonID,
                TerritoryWithMostProfit,
                CustomerCountForTerritoryWithMostProfit
            FROM (
                SELECT
                    SalesPersonID,
                    TerritoryWithMostProfit,
                    CustomerCountForTerritoryWithMostProfit,
                    dense_rank() OVER (PARTITION BY SalesPersonID ORDER BY TerritoryProfit DESC) AS TerritoryRank
                FROM (
                    SELECT
                        SalesPersonID,
                        Territory AS TerritoryWithMostProfit,
                        COUNT(DISTINCT c.CustomerID) AS CustomerCountForTerritoryWithMostProfit,
                        SUM(Profit) AS TerritoryProfit
                    FROM #panel_TestEmployee43
                    JOIN Sales.Customer c ON #panel_TestEmployee43.CustomerID = c.CustomerID
                    WHERE UnitProfit > 0
                    GROUP BY SalesPersonID, Territory
                ) AS TerritorySummary
            ) AS TerritorySummaryRanked
            WHERE TerritoryRank = 1
        ) AS t1 ON p.SalesPersonID = t1.SalesPersonID
        ORDER BY p.Rank ASC;

        -- Commit the Second Query Transaction
        IF @@TRANCOUNT > 0
            COMMIT TRANSACTION SecondQueryTransaction;

        -- Third Query Transaction: Analyze the best-selling territory for each year
        BEGIN TRANSACTION ThirdQueryTransaction;

        -- Third Query: Retrieve information about the best-selling territory for each year
        IF @SelectedYear IS NULL
        BEGIN
            SELECT
                YearSale AS [Year],
                Territory AS BestSellingTerritory,
                TotalProfit
            FROM (
                SELECT
                    YEAR_sale AS YearSale,
                    Territory,
                    SUM(Profit) AS TotalProfit,
                    DENSE_RANK() OVER (PARTITION BY YEAR_sale ORDER BY SUM(Profit) DESC) AS TerritoryRank
                FROM #panel_TestEmployee43
                WHERE UnitProfit > 0
                GROUP BY YEAR_sale, Territory
            ) AS YearlyTerritoryProfit
            WHERE TerritoryRank = 1
            ORDER BY YearSale;
        END
        ELSE
        BEGIN
            -- Fourth Query Transaction: Analyze the best-selling territory for a specific year
            BEGIN TRANSACTION FourthQueryTransaction;

            -- Fourth Query: Retrieve information about the best-selling territory for a specific year
            SELECT
                @SelectedYear AS [Year],
                Territory AS BestSellingTerritory,
                TotalProfit
            FROM (
                SELECT
                    YEAR_sale AS YearSale,
                    Territory,
                    SUM(Profit) AS TotalProfit,
                    DENSE_RANK() OVER (PARTITION BY YEAR_sale ORDER BY SUM(Profit) DESC) AS TerritoryRank
                FROM #panel_TestEmployee43
                WHERE UnitProfit > 0 AND YEAR_sale = @SelectedYear
                GROUP BY YEAR_sale, Territory
            ) AS YearlyTerritoryProfit
            WHERE TerritoryRank = 1;

            -- Commit the Fourth Query Transaction
            IF @@TRANCOUNT > 0
                COMMIT TRANSACTION FourthQueryTransaction;
        END

        -- Commit the Third Query Transaction
        IF @@TRANCOUNT > 0
            COMMIT TRANSACTION ThirdQueryTransaction;
    END TRY
    BEGIN CATCH
        -- If an error occurs, rollback the outermost transaction
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION OuterTransaction;
        -- You may choose to handle the error in a way suitable for your application
    END CATCH;

    -- Drop the temporary table outside the try-catch block to ensure it always gets dropped to free up memory
    DROP TABLE IF EXISTS #panel_TestEmployee43;

    -- Commit the outermost transaction if no error occurred
    IF @@TRANCOUNT > 0
        COMMIT TRANSACTION OuterTransaction;
END;



-- COMMANDS TO EXECUTE THE PROCEDURE ABOVE :

-- Execute the stored procedure without specifying a year (NULL by default)
EXEC spPerformance;

-- Execute the stored procedure for the desired year (example 2011)
EXEC spPerformance @SelectedYear = 2011;

-- Execute the stored procedure for all years (NULL parameter)
EXEC spPerformance @SelectedYear = NULL;
