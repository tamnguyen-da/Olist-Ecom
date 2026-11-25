With orders AS (
    SELECT
        order_id,
        customer_id,
        order_status,
        order_purchase_timestamp,
        order_delivered_carrier_date,
        order_delivered_customer_date,
        order_estimated_delivery_date
    FROM olist_orders_dataset
    WHERE 
    -- loại những order đã giao nhưng ngày giao cho khách bị trống
        order_status = 'delivered' AND order_delivered_customer_date IS NOT NULL
    -- loại những orders conflict về mặt time và quy trình
        AND order_estimated_delivery_date > order_delivered_customer_date
        AND order_delivered_customer_date > order_delivered_carrier_date
        AND order_delivered_carrier_date > order_approved_at
        AND order_approved_at > order_purchase_timestamp
    ),
customer_type AS (
    SELECT
        c.customer_unique_id,
        count(distinct o.order_id) AS total_orders,
        case when count(DISTINCT o.order_id) > 1 then 'Returning Customer' else 'New Customer' end as customer_type
    FROM orders o
    INNER JOIN olist_customers_dataset c
    ON o.customer_id = c.customer_id
    GROUP BY c.customer_unique_id
    )
select
    o.*,
    c.customer_unique_id,
    c.customer_state,
    c.customer_city,
    ct.total_orders,
    ct.customer_type,
    ROW_NUMBER() OVER(PARTITION BY c.customer_unique_id
                        ORDER BY o.order_purchase_timestamp ASC
    ) as purchase_seq
from orders o
inner join olist_customers_dataset c
on o.customer_id = c.customer_id
inner join customer_type ct
on c.customer_unique_id = ct.customer_unique_id
WHERE ct.customer_type = 'Returning Customer'
ORDER BY total_orders desc, customer_unique_id, purchase_seq desc