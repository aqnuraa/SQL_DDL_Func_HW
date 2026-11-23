-- DDL Statements. Function: Tasks 1-5, applying view
-- TASK 1: Creating a dynamic quarterly sales revenue view

CREATE OR REPLACE VIEW public.sales_revenue_by_category_qtr AS
SELECT
    c.name AS category,
    SUM(p.amount) AS total_sales_revenue
FROM public.payment p
JOIN public.rental r
    ON p.rental_id = r.rental_id
JOIN public.inventory i
    ON r.inventory_id = i.inventory_id
JOIN public.film_category fc
    ON i.film_id = fc.film_id
JOIN public.category c
    ON fc.category_id = c.category_id
WHERE p.payment_date >= DATE_TRUNC('quarter', CURRENT_DATE)
  AND p.payment_date < DATE_TRUNC('quarter', CURRENT_DATE)
                       + INTERVAL '3 months'
GROUP BY c.category_id, c.name
HAVING SUM(p.amount) > 0;

SELECT *
FROM public.sales_revenue_by_category_qtr;


COMMENT ON VIEW public.sales_revenue_by_category_qtr IS
'This view calculates total sales revenue by film category
for the current quarter and year.

CURRENT_DATE determines the current year automatically.
DATE_TRUNC(''quarter'', CURRENT_DATE) determines the
beginning of the current quarter.

Payments are connected to categories through rental,
inventory, and film_category.

INNER JOIN ensures that only categories with matching
payment records are included.
HAVING SUM(p.amount) > 0 excludes zero-revenue categories.

The view is dynamic and updates automatically when
the current quarter changes.

The sample database contains historical payments,
so the current quarter may return zero rows.';


SELECT *
FROM public.sales_revenue_by_category_qtr
ORDER BY total_sales_revenue DESC;


SELECT *
FROM public.sales_revenue_by_category_qtr
WHERE total_sales_revenue <= 0;


SELECT
    EXTRACT(YEAR FROM payment_date)::int AS sales_year,
    EXTRACT(QUARTER FROM payment_date)::int AS sales_quarter,
    COUNT(*) AS total_payments,
    SUM(amount) AS total_revenue
FROM public.payment
GROUP BY 1, 2
ORDER BY 1, 2;



-- TASK 2: Sales revenue by category for a selected quarter
-- Input format: YYYY-Q1, YYYY-Q2, YYYY-Q3, or YYYY-Q4
-- NULL uses the current year and quarter automatically.
-- The parameter allows testing historical periods.
-- Invalid formats or quarters return no rows.
-- Periods without payments also return no rows.
-- INNER JOIN and HAVING exclude zero-revenue categories.

CREATE OR REPLACE FUNCTION public.get_sales_revenue_by_category_qtr(
    p_period TEXT DEFAULT NULL
)
RETURNS TABLE (
    category VARCHAR(25),
    total_sales_revenue NUMERIC
)
LANGUAGE SQL
STABLE
AS $$
    SELECT
        c.name AS category,
        SUM(p.amount) AS total_sales_revenue
    FROM public.payment p
    JOIN public.rental r
        ON p.rental_id = r.rental_id
    JOIN public.inventory i
        ON r.inventory_id = i.inventory_id
    JOIN public.film_category fc
        ON i.film_id = fc.film_id
    JOIN public.category c
        ON fc.category_id = c.category_id
    CROSS JOIN LATERAL (
        SELECT COALESCE(
            p_period,
            TO_CHAR(CURRENT_DATE, 'YYYY') || '-Q' ||
            EXTRACT(QUARTER FROM CURRENT_DATE)::int
        ) AS period_value
    ) params
    WHERE params.period_value ~
          '^[0-9]{4}-Q[1-4]$'
      AND p.payment_date >=
          MAKE_DATE(
              LEFT(params.period_value, 4)::int,
              1,
              1
          )
          + (
              (RIGHT(params.period_value, 1)::int - 1)
              * INTERVAL '3 months'
          )
      AND p.payment_date <
          MAKE_DATE(
              LEFT(params.period_value, 4)::int,
              1,
              1
          )
          + (
              RIGHT(params.period_value, 1)::int
              * INTERVAL '3 months'
          )
    GROUP BY c.category_id, c.name
    HAVING SUM(p.amount) > 0;
$$;

SELECT *
FROM public.get_sales_revenue_by_category_qtr('2017-Q2')
ORDER BY total_sales_revenue DESC;

SELECT *
FROM public.get_sales_revenue_by_category_qtr('2017-Q5');

SELECT *
FROM public.get_sales_revenue_by_category_qtr();



SELECT
    table_name,
    column_name,
    data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN (
      'country',
      'city',
      
      'address',
      'customer',
      'rental',
      'inventory',
      'film',
      'language'
  )
ORDER BY table_name, ordinal_position;



-- TASK 3: Most popular film by country
-- Popularity is measured by the number of rentals.
-- Countries are matched case-insensitively.
-- Ties are resolved alphabetically by film title.
-- Countries with no rentals return NULL film details.
-- Duplicate country inputs are removed.

CREATE OR REPLACE FUNCTION public.most_popular_films_by_countries(
    p_countries TEXT[]
)
RETURNS TABLE (
    country TEXT,
    film TEXT,
    rating TEXT,
    language TEXT,
    length INTEGER,
    release_year INTEGER
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_countries IS NULL
       OR array_length(p_countries, 1) IS NULL THEN
        RAISE EXCEPTION 'Country array cannot be empty';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM unnest(p_countries) AS x(country_name)
        WHERE country_name IS NULL
           OR btrim(country_name) = ''
    ) THEN
        RAISE EXCEPTION 'Country names cannot be NULL or empty';
    END IF;

    RETURN QUERY
    WITH input_countries AS (
        SELECT DISTINCT
            btrim(x.country_name) AS country_name
        FROM unnest(p_countries) AS x(country_name)
    ),
    rental_counts AS (
        SELECT
            co.country_id,
            f.film_id,
            COUNT(*) AS rental_count
        FROM public.country co
        JOIN public.city ci
            ON ci.country_id = co.country_id
        JOIN public.address a
            ON a.city_id = ci.city_id
        JOIN public.customer cu
            ON cu.address_id = a.address_id
        JOIN public.rental r
            ON r.customer_id = cu.customer_id
        JOIN public.inventory i
            ON i.inventory_id = r.inventory_id
        JOIN public.film f
            ON f.film_id = i.film_id
        GROUP BY co.country_id, f.film_id
    ),
    ranked_films AS (
        SELECT
            rc.country_id,
            f.title,
            f.rating::TEXT AS film_rating,
            l.name AS film_language,
            f.length AS film_length,
            f.release_year AS film_year,
            ROW_NUMBER() OVER (
                PARTITION BY rc.country_id
                ORDER BY rc.rental_count DESC,
                         f.title ASC,
                         f.film_id ASC
            ) AS rn
        FROM rental_counts rc
        JOIN public.film f
            ON f.film_id = rc.film_id
        JOIN public.language l
            ON l.language_id = f.language_id
    )
    SELECT
        ic.country_name::TEXT,
        rf.title::TEXT,
        rf.film_rating,
        rf.film_language::TEXT,
        rf.film_length::INTEGER,
        rf.film_year::INTEGER
    FROM input_countries ic
    LEFT JOIN public.country co
        ON lower(co.country) = lower(ic.country_name)
    LEFT JOIN ranked_films rf
        ON rf.country_id = co.country_id
       AND rf.rn = 1
    ORDER BY ic.country_name;
END;
$$;


SELECT
    routine_schema,
    routine_name
FROM information_schema.routines
WHERE routine_name = 'most_popular_films_by_countries';

SELECT current_database(), current_schema();

SELECT
    n.nspname AS schema_name,
    p.proname AS function_name,
    pg_get_function_identity_arguments(p.oid) AS arguments
FROM pg_proc p
JOIN pg_namespace n
    ON n.oid = p.pronamespace
WHERE p.proname = 'most_popular_films_by_countries';

SELECT *
FROM public.most_popular_films_by_countries(
    ARRAY['Afghanistan', 'Brazil', 'United States']::TEXT[]
);


SELECT *
FROM public.most_popular_films_by_countries(
    ARRAY['Nonexistent Country']::TEXT[]
);


SELECT *
FROM public.most_popular_films_by_countries(
    ARRAY[]::TEXT[]
);



SELECT
    f.title,
    COUNT(i.inventory_id) AS inventory_copies
FROM public.film f
JOIN public.inventory i
    ON f.film_id = i.film_id
WHERE f.title ILIKE '%love%'
GROUP BY f.film_id, f.title
ORDER BY f.title;



-- TASK 4: Find available films by partial title
--
-- ILIKE performs case-insensitive pattern matching.
-- % matches any sequence of characters.
-- The function first filters matching films to reduce
-- unnecessary processing.
--
-- A copy is available when its latest rental has been
-- returned or when it has never been rented.
--
-- Customer name and rental date refer to the LAST
-- rental of an available copy, not a current rental.
--
-- Multiple matches return separate numbered rows.
-- If no copies match, a descriptive message is returned.
-- NULL or empty input raises an exception.

CREATE OR REPLACE FUNCTION public.films_in_stock_by_title(
    p_title TEXT
)
RETURNS TABLE (
    row_num BIGINT,
    film_title TEXT,
    language TEXT,
    customer_name TEXT,
    rental_date TIMESTAMP
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_title IS NULL OR btrim(p_title) = '' THEN
        RAISE EXCEPTION 'Film title pattern cannot be empty';
    END IF;

    RETURN QUERY
    WITH matching_films AS (
        SELECT
            f.film_id,
            f.title,
            l.name AS language_name
        FROM public.film f
        JOIN public.language l
            ON l.language_id = f.language_id
        WHERE f.title ILIKE p_title
    ),
    available_copies AS (
        SELECT
            mf.title,
            mf.language_name,
            i.inventory_id,
            c.first_name || ' ' || c.last_name
                AS last_customer,
            lr.rental_date AS last_rental_date
        FROM matching_films mf
        JOIN public.inventory i
            ON i.film_id = mf.film_id

        LEFT JOIN LATERAL (
            SELECT
                r.rental_id,
                r.customer_id,
                r.rental_date,
                r.return_date
            FROM public.rental r
            WHERE r.inventory_id = i.inventory_id
            ORDER BY r.rental_date DESC,
                     r.rental_id DESC
            LIMIT 1
        ) lr ON TRUE

        LEFT JOIN public.customer c
            ON c.customer_id = lr.customer_id

        WHERE lr.rental_id IS NULL
           OR lr.return_date IS NOT NULL
    )
    SELECT
        ROW_NUMBER() OVER (
            ORDER BY ac.title, ac.inventory_id
        ),
        ac.title::TEXT,
        ac.language_name::TEXT,
        ac.last_customer::TEXT,
        ac.last_rental_date::TIMESTAMP
    FROM available_copies ac;

    IF NOT FOUND THEN
        RETURN QUERY
        SELECT
            NULL::BIGINT,
            'Film not found in stock'::TEXT,
            NULL::TEXT,
            NULL::TEXT,
            NULL::TIMESTAMP;
    END IF;
END;
$$;


-- Test 1: Valid input
SELECT *
FROM public.films_in_stock_by_title('%love%');

-- Test 2: Film not found
SELECT *
FROM public.films_in_stock_by_title('%xyznonexistentfilm%');

-- Test 3: Check customer information
SELECT
    COUNT(*) AS total_rows,
    COUNT(customer_name) AS rows_with_customer,
    COUNT(rental_date) AS rows_with_rental_date
FROM public.films_in_stock_by_title('%love%');

-- Test 4: Invalid input (run separately)
-- SELECT *
-- FROM public.films_in_stock_by_title(NULL);


INSERT INTO public.language (name)
SELECT 'Klingon'
WHERE NOT EXISTS (
    SELECT 1
    FROM public.language
    WHERE LOWER(TRIM(name)) = 'klingon'
);


SELECT language_id, name
FROM public.language
WHERE LOWER(TRIM(name)) = 'klingon';



-- TASK 5: Create procedure language function new_movie

-- Unique ID:
-- film_id uses the existing film table sequence/default.
-- The database generates a new ID automatically.

-- Duplicate prevention:
-- A case-insensitive title check rejects existing titles.
-- An advisory transaction lock serializes calls to this function
-- so concurrent calls cannot insert the same title.

-- Existing movie:
-- The function raises an exception and does not insert a row.

-- Language validation:
-- The language name is checked against public.language.
-- An exception is raised if the language does not exist.

-- Insertion failure and consistency:
-- PostgreSQL rolls back the failed statement.
-- No partially inserted movie is retained.

CREATE OR REPLACE FUNCTION public.new_movie(
    p_title TEXT,
    p_release_year INTEGER DEFAULT NULL,
    p_language TEXT DEFAULT 'Klingon'
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_film_id INTEGER;
    v_language_id INTEGER;
    v_year INTEGER;
    v_title TEXT;
BEGIN
    v_title := BTRIM(p_title);

    IF v_title IS NULL OR v_title = '' THEN
        RAISE EXCEPTION 'Movie title cannot be empty';
    END IF;

    v_year := COALESCE(
        p_release_year,
        EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
    );

    -- Serialize inserts made through this function.
    PERFORM pg_advisory_xact_lock(
        hashtext('public.new_movie'),
        hashtext(LOWER(v_title))
    );

    -- Check for duplicate titles.
    IF EXISTS (
        SELECT 1
        FROM public.film f
        WHERE LOWER(BTRIM(f.title)) = LOWER(v_title)
    ) THEN
        RAISE EXCEPTION 'Movie already exists: %', v_title;
    END IF;

    -- Validate the requested language.
    SELECT l.language_id
    INTO v_language_id
    FROM public.language l
    WHERE LOWER(BTRIM(l.name)) = LOWER(BTRIM(p_language))
    ORDER BY l.language_id
    LIMIT 1;

    IF v_language_id IS NULL THEN
        RAISE EXCEPTION 'Language does not exist: %', p_language;
    END IF;

    -- Insert the new movie.
    INSERT INTO public.film (
        title,
        release_year,
        language_id,
        rental_duration,
        rental_rate,
        replacement_cost
    )
    VALUES (
        v_title,
        v_year,
        v_language_id,
        3,
        4.99,
        19.99
    )
    RETURNING film_id INTO v_film_id;

    RETURN v_film_id;
END;
$$;


-- Test 1: testing the function
SELECT public.new_movie(
    'MY TEST MOVIE 2026',
    2026,
    'English'
);


--Verification

SELECT
    f.film_id,
    f.title,
    f.release_year,
    l.name AS language,
    f.rental_duration,
    f.rental_rate,
    f.replacement_cost
FROM public.film f
JOIN public.language l
    ON f.language_id = l.language_id
WHERE f.title = 'MY TEST MOVIE 2026';


-- Test 2: testing the duplicate prevention

/* SELECT public.new_movie(
    'MY TEST MOVIE 2026',
    2026,
    'English'
);

*/

/* Test 3: language validation
SELECT public.new_movie(
    'ANOTHER TEST MOVIE 2026',
    2026,
    'NonexistentLanguage'
); */


-- Testing the default parameters
SELECT public.new_movie('DEFAULT MOVIE TEST 2026');





