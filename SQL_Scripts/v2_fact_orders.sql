/* ---------------------------------------------------------------------
   VIEW 1: v2_fact_orders  — 1 dòng / 1 đơn hàng
   Thay đổi so với bản cũ:
   (1) Giữ kiểu DATE thật (CAST), không dùng FORMAT() -> FORMAT trả về
       chuỗi, Power BI phải đổi kiểu lại và chạy chậm.
   (2) Cửa sổ thời gian cố định 2017-01-01 -> 2018-06-30 (bỏ 2016 rời rạc
       và tháng 9-10/2018 gần như không có đơn).
   (3) Thêm cờ is_delivered / is_canceled -> doanh thu chỉ tính đơn đã giao.
   (4) Thêm chỉ số giao hàng: delivery_days, promised_days, days_late, is_late.
   (5) Thêm review_score (1 review / đơn).
   (6) Thêm customer_order_seq: đây là đơn thứ mấy của khách
       -> phân biệt doanh thu khách MỚI và khách QUAY LẠI.
   --------------------------------------------------------------------- */
ALTER VIEW v2_fact_orders AS
WITH items AS (
    SELECT
        order_id,
        SUM(price)                AS item_value,
        SUM(freight_value)        AS freight_value,
        COUNT(*)                  AS item_count,
        COUNT(DISTINCT seller_id) AS seller_count
    FROM olist_order_items_dataset
    GROUP BY order_id
),
pay AS (
    SELECT order_id, SUM(payment_value) AS payment_value
    FROM olist_order_payments_dataset
    GROUP BY order_id
),
review_one AS (
    -- Một số đơn có >1 review -> lấy review trả lời gần nhất để tránh nhân dòng
    SELECT order_id, review_score
    FROM (
        SELECT order_id, review_score,
               ROW_NUMBER() OVER (PARTITION BY order_id
                                  ORDER BY review_answer_timestamp DESC) AS rn
        FROM olist_order_reviews_dataset
    ) r
    WHERE rn = 1
),
base AS (
    SELECT
        o.order_id,
        c.customer_unique_id,
        c.customer_state,
        c.customer_city,
        o.order_status,
        o.order_purchase_timestamp,
        o.order_delivered_customer_date,
        o.order_estimated_delivery_date,
        i.item_value,
        i.freight_value,
        i.item_count,
        i.seller_count,
        p.payment_value,
        rv.review_score,
        CASE WHEN o.order_status = 'delivered'
              AND o.order_delivered_customer_date IS NOT NULL
             THEN 1 ELSE 0 END AS is_delivered,
        CASE WHEN o.order_status IN ('canceled', 'unavailable')
             THEN 1 ELSE 0 END AS is_canceled
    FROM olist_orders_dataset o
    JOIN items i                     ON o.order_id = i.order_id
    JOIN pay   p                     ON o.order_id = p.order_id
    JOIN olist_customers_dataset c   ON o.customer_id = c.customer_id
    LEFT JOIN review_one rv          ON o.order_id = rv.order_id
    WHERE o.order_purchase_timestamp >= '2017-01-01'
      AND o.order_purchase_timestamp <  '2018-07-01'
),
ranked AS (
    SELECT *,
        CASE WHEN is_delivered = 1 THEN
            ROW_NUMBER() OVER (PARTITION BY customer_unique_id, is_delivered
                               ORDER BY order_purchase_timestamp, order_id) END AS customer_order_seq
    FROM base
)
SELECT
    order_id,
    customer_unique_id,
    customer_state,
    customer_city,
    order_status,
    is_delivered,
    is_canceled,
    CAST(order_purchase_timestamp      AS date) AS purchase_date,
    CAST(order_delivered_customer_date AS date) AS delivered_date,
    CAST(order_estimated_delivery_date AS date) AS estimated_date,

    ROUND(item_value, 2)    AS item_value,     -- tiền hàng (price)
    ROUND(freight_value, 2) AS freight_value,  -- phí ship
    ROUND(payment_value, 2) AS payment_value,  -- khách trả (≈ hàng + ship)
    item_count,
    seller_count,
    review_score,

    -- ===== Chỉ số giao hàng (chỉ có ý nghĩa với đơn đã giao) =====
    CASE WHEN is_delivered = 1 THEN
        DATEDIFF(day, CAST(order_purchase_timestamp AS date),
                      CAST(order_delivered_customer_date AS date)) END AS delivery_days,
    DATEDIFF(day, CAST(order_purchase_timestamp AS date),
                  CAST(order_estimated_delivery_date AS date))      AS promised_days,
    CASE WHEN is_delivered = 1 THEN
        DATEDIFF(day, CAST(order_estimated_delivery_date AS date),
                      CAST(order_delivered_customer_date AS date)) END AS days_late,
    CASE WHEN is_delivered = 1 THEN
        CASE WHEN CAST(order_delivered_customer_date AS date)
                > CAST(order_estimated_delivery_date AS date)
             THEN 1 ELSE 0 END END AS is_late,

    -- Nhóm "trễ bao nhiêu ngày" để vẽ biểu đồ Review vs Độ trễ
    CASE WHEN is_delivered = 0 THEN NULL
         WHEN DATEDIFF(day, CAST(order_estimated_delivery_date AS date), CAST(order_delivered_customer_date AS date)) <= -8 THEN '1. 8+ days early'
         WHEN DATEDIFF(day, CAST(order_estimated_delivery_date AS date), CAST(order_delivered_customer_date AS date)) <= -1 THEN '2. 1-7 days early'
         WHEN DATEDIFF(day, CAST(order_estimated_delivery_date AS date), CAST(order_delivered_customer_date AS date)) =  0 THEN '3. On the day'
         WHEN DATEDIFF(day, CAST(order_estimated_delivery_date AS date), CAST(order_delivered_customer_date AS date)) <= 3  THEN '4. 1-3 days late'
         WHEN DATEDIFF(day, CAST(order_estimated_delivery_date AS date), CAST(order_delivered_customer_date AS date)) <= 7  THEN '5. 4-7 days late'
         ELSE '6. 8+ days late' END AS delivery_bucket,

    -- Đơn thứ mấy của khách (chỉ đếm đơn đã giao). 1 = khách mới
    customer_order_seq,
    -- Đơn của khách MỚI hay QUAY LẠI (NULL nếu chưa giao)
    CASE WHEN customer_order_seq = 1 THEN 'New'
         WHEN customer_order_seq > 1 THEN 'Returning' END AS customer_type
FROM ranked;
GO

