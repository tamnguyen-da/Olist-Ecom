
---------------------------------------------------------------- CLEANING DATA PART------------------------------------------------
/* 1. without price and freight_value, we cannot calculate full_price
 and total_payment, so we will exclude those records from the view
2. shipping year is null (2965 rows) which could be mean the order was not delivered yet
-> check if the order status is not delivered -> remove if wrong */
select distinct year(orders.order_delivered_customer_date) as shipping_year, count(*) as total_records
from olist_orders_dataset orders
group by year(orders.order_delivered_customer_date);

-- Check total_price logic
select
    customer_unique_id,
    price
from olist_customers_dataset as customers
join olist_orders_dataset as orders
on customers.customer_id = orders.customer_id
join olist_order_items_dataset as order_items
on orders.order_id = order_items.order_id
where customers.customer_unique_id = '8d50f5eadf50201ccdcedfb9e2ac8455'

select
    customer_unique_id,
    count(customers.customer_id) as total_orders,
    sum(order_items.price) as total_price
from olist_customers_dataset as customers
join olist_orders_dataset as orders
on customers.customer_id = orders.customer_id
join olist_order_items_dataset as order_items
on orders.order_id = order_items.order_id
where customers.customer_unique_id = '8d50f5eadf50201ccdcedfb9e2ac8455'
group by customer_unique_id;

-- data 2016 is quite small and not complete, we will exclude it from the view
select
    year(order_purchase_timestamp) as purchase_year,
    month(order_purchase_timestamp) as purchase_month,
    sum(price) as total_price
from olist_order_items_dataset as order_items
join olist_orders_dataset as orders
on order_items.order_id = orders.order_id
where price is not null
group by year(order_purchase_timestamp), month(order_purchase_timestamp)
order by purchase_year, purchase_month;



---------------------------------------------------------------- CREATE VIEW PART------------------------------------------------
--VIEW 1: Bảng Fact 1 (fact_orders): Chỉ chứa thông tin tổng quan của đơn hàng (Mỗi order_id là 1 dòng duy nhất), chứa thông tin ngày mua, trạng thái, và Tổng tiền thanh toán.

drop view IF EXISTS fact_orders ;
GO

create or alter view fact_orders as 

WITH order_items as (
select
    order_id,
    sum(total_price) as total_price,
    sum(total_freight) as total_freight
from(
    select 
        distinct order_id,
        sum(price) as total_price,
        sum(freight_value) as total_freight
    from olist_order_items_dataset as order_items
    group by order_id
    ) as subquery
group by order_id
)
,
order_payments as (
-- order_payments groupby order_id
SELECT
    order_id,
    sum(total_payment) as total_payment
from(
    select 
        distinct order_id,
        sum(payment_value) as total_payment
    from olist_order_payments_dataset as order_payments
    group by order_id
    ) as subquery
group by order_id
)
,
--- create orders_clean to exclude records with null shipping year and order status is delivered or shipped

v_orders_clean as (
select *
from olist_orders_dataset
where not (order_delivered_customer_date is null and order_status in ('delivered', 'shipped'))
)

-- create fact_orders view
select
    orders.order_id,
    orders.customer_id,
    customers.customer_unique_id,
    orders.order_status,
    format(orders.order_purchase_timestamp, 'yyyy-MM-dd') as order_purchase_date,
    format(orders.order_approved_at, 'yyyy-MM-dd') as order_approved_date,
    format(orders.order_delivered_customer_date, 'yyyy-MM-dd') as order_shipping_date,
    round(order_items.total_price, 2) as total_price,
    round(order_items.total_freight, 2) as total_freight,
    round(order_payments.total_payment,2) as total_payment
from v_orders_clean as orders
join order_items
on orders.order_id = order_items.order_id      
join order_payments
on orders.order_id = order_payments.order_id
join olist_customers_dataset as customers
on orders.customer_id = customers.customer_id
where year(orders.order_purchase_timestamp) >= 2017;
GO  


-- VIEW 2: Bảng Fact 2 (fact_order_details hoặc fact_order_items): Chứa thông tin chi tiết từng sản phẩm trong đơn hàng (Một order_id có thể có nhiều dòng), chứa product_id, price, freight_value.

drop view if exists fact_order_items_detail;
GO

CREATE OR ALTER VIEW fact_order_items_detail AS
SELECT 
    oi.order_id,
    oi.product_id,
    ISNULL(p.product_category_name, 'Unclassified') AS product_category_name,
    ROUND(oi.price, 2) AS price,
    ROUND(oi.freight_value, 2) AS freight_value
FROM olist_order_items_dataset oi
LEFT JOIN olist_products_dataset p ON oi.product_id = p.product_id;
GO

--VIEW 3: View fact_customer_profile: Chứa thông tin tổng hợp về khách hàng, bao gồm độ gần đây của đơn hàng cuối cùng (Recency), tần suất mua hàng (Frequency), và tổng giá trị mua hàng (Monetary).
drop view if exists fact_customer_profile;
GO

CREATE OR ALTER VIEW fact_customer_profile AS

WITH customer_orders_ranked AS (
    SELECT 
        cust.customer_unique_id,-- Tính RFM theo thực thể NGƯỜI DÙNG (Unique ID)
        o.order_id,
        cust.customer_city,   -- Lấy thêm thành phố từ bảng khách hàng gốc
        cust.customer_state,  -- Lấy thêm bang từ bảng khách hàng gốc
        o.order_purchase_date,
        o.total_payment,
        ROW_NUMBER() OVER (
            PARTITION BY cust.customer_unique_id 
            ORDER BY o.order_purchase_date DESC
        ) AS rn
    FROM fact_orders o
    JOIN olist_customers_dataset cust ON o.customer_id = cust.customer_id
),
customer_geo_clean AS (
    -- Chỉ nhặt ra thông tin thành phố của đơn hàng MỚI NHẤT của khách hàng đó
    SELECT customer_unique_id, customer_city, customer_state
    FROM customer_orders_ranked
    WHERE rn = 1
),
customer_rfm_stats AS (
    -- Tính toán RFM độc lập theo ID
    SELECT 
        customer_unique_id,
        MAX(order_purchase_date) AS last_purchase_date,
        COUNT(order_id) AS Frequency,
        SUM(total_payment) AS Monetary
    FROM customer_orders_ranked
    GROUP BY customer_unique_id
),
max_date_cte AS (
    SELECT MAX(order_purchase_date) AS max_system_date FROM fact_orders
)
SELECT 
    rfm.customer_unique_id,
    geo.customer_city,
    geo.customer_state,
    rfm.last_purchase_date,
    DATEDIFF(day, rfm.last_purchase_date, (SELECT max_system_date FROM max_date_cte)) AS Recency,
    rfm.Frequency,
    rfm.Monetary
FROM customer_rfm_stats rfm
JOIN customer_geo_clean geo ON rfm.customer_unique_id = geo.customer_unique_id;
GO

select count(DISTINCT customer_unique_id), count( customer_unique_id)
from fact_customer_profile

-- VIEW 4: Lọc lại bảng payment đã loại bỏ những dòng với các điều kiện ở bảng fact_orders để đồng nhất revenue

drop view if exists v_payments_clean;
GO

CREATE OR ALTER VIEW v_payments_clean AS
SELECT 
    p.order_id,
    p.payment_sequential,
    p.payment_type,
    p.payment_installments,
    p.payment_value
FROM olist_order_payments_dataset p
WHERE EXISTS (
    -- Kiểm tra xem order_id này có tồn tại trong danh sách đơn hàng đã được lọc sạch hay không
    SELECT 1 
    FROM fact_orders o
    WHERE o.order_id = p.order_id
);
GO