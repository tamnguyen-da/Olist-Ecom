/* =====================================================================
   OLIST E-COM — DATA LAYER v2
   ---------------------------------------------------------------------
   - KHÔNG đụng vào các view cũ (fact_orders, fact_customer_profile,...).
     Bản .pbix gốc vẫn chạy bình thường.
   - Tất cả view mới có tiền tố v2_.
   - Yêu cầu: đã import thêm 2 bảng vào SQL Server
       olist_order_reviews_dataset
       product_category_name_translation
     (xem HUONG_DAN_v2.md, Bước 0)
   ===================================================================== */


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
CREATE OR ALTER VIEW v2_fact_orders AS
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

-- Kiểm tra nhanh (kết quả mong đợi: 85628 | 83696 | 13361699.14)
-- SELECT COUNT(*), SUM(is_delivered), SUM(CASE WHEN is_delivered=1 THEN payment_value END) FROM v2_fact_orders;


/* ---------------------------------------------------------------------
   VIEW 2: v2_fact_order_items — 1 dòng / 1 sản phẩm trong đơn
   Thay đổi: thêm seller_id, tên ngành hàng tiếng Anh, và "mang theo"
   cờ giao hàng + review từ đơn -> phân tích theo ngành hàng / seller
   mà không cần quan hệ 2 chiều (bi-directional) trong model.
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW v2_fact_order_items AS
SELECT
    oi.order_id,
    oi.order_item_id,
    oi.product_id,
    oi.seller_id,
    COALESCE(t.product_category_name_english,
             p.product_category_name, 'unknown') AS category,
    ROUND(oi.price, 2)         AS price,
    ROUND(oi.freight_value, 2) AS freight_value,
    f.purchase_date,
    f.is_delivered,
    f.is_late,
    f.review_score
FROM olist_order_items_dataset oi
JOIN v2_fact_orders f                        ON oi.order_id = f.order_id
LEFT JOIN olist_products_dataset p           ON oi.product_id = p.product_id
LEFT JOIN product_category_name_translation t
       ON p.product_category_name = t.product_category_name;
GO


/* ---------------------------------------------------------------------
   VIEW 3: v2_dim_customer — 1 dòng / 1 khách (customer_unique_id)
   Thay đổi lớn nhất:
   - Đổi tên fact_customer_profile -> dim_customer (đây là bảng mô tả
     khách hàng, đúng vai trò "dimension" trong star schema).
   - THAY K-Means bằng phân khúc theo luật (rule-based) dễ giải thích:
       97% khách chỉ mua 1 lần -> Frequency gần như không phân biệt được ai,
       K-Means chỉ đang cắt theo tiền và độ gần đây, và số thứ tự cluster
       (0,1,2,3) có thể đổi chỗ khi dữ liệu đổi -> nhãn DAX bị sai.
   - Thêm thông tin trải nghiệm ĐƠN ĐẦU TIÊN (trễ hay không, review mấy sao)
     -> trả lời: trải nghiệm đơn đầu có ảnh hưởng tới việc quay lại không?
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW v2_dim_customer AS
WITH d AS (   -- chỉ đơn đã giao
    SELECT *,
           customer_order_seq AS rn_first,
           ROW_NUMBER() OVER (PARTITION BY customer_unique_id ORDER BY purchase_date DESC, order_id) AS rn_last
    FROM v2_fact_orders
    WHERE is_delivered = 1
),
ref AS (SELECT MAX(purchase_date) AS ref_date FROM d),
stats AS (
    SELECT customer_unique_id,
           MIN(purchase_date) AS first_purchase_date,
           MAX(purchase_date) AS last_purchase_date,
           COUNT(*)           AS frequency,
           SUM(payment_value) AS monetary
    FROM d
    GROUP BY customer_unique_id
),
p80 AS (  -- ngưỡng "giá trị cao" = top 20% khách theo tổng chi tiêu
    SELECT DISTINCT PERCENTILE_CONT(0.8) WITHIN GROUP (ORDER BY monetary) OVER () AS p80,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY monetary) OVER () AS p50   -- trung vị: tách Mid-Value / Low-Value
    FROM stats
),
all_cust AS (   -- gồm cả khách chưa có đơn giao thành công
    SELECT customer_unique_id,
           customer_state, customer_city,
           ROW_NUMBER() OVER (PARTITION BY customer_unique_id ORDER BY purchase_date DESC, order_id) AS rn
    FROM v2_fact_orders
)
SELECT
    a.customer_unique_id,
    a.customer_state,                       -- địa chỉ của đơn gần nhất
    a.customer_city,
    s.first_purchase_date,
    s.last_purchase_date,
    ISNULL(s.frequency, 0)                  AS frequency,
    ROUND(s.monetary, 2)                    AS monetary,
    DATEDIFF(day, s.last_purchase_date, (SELECT ref_date FROM ref)) AS recency_days,

    -- Trải nghiệm đơn đầu tiên
    CASE fo.is_late WHEN 1 THEN 'Late' WHEN 0 THEN 'On time' END AS first_order_delivery,
    fo.review_score                          AS first_order_review,

    -- Khách "đủ tuổi" để đánh giá quay lại: đơn đầu cách ngày cuối dữ liệu >= 90 ngày
    CASE WHEN DATEDIFF(day, s.first_purchase_date, (SELECT ref_date FROM ref)) >= 90
         THEN 1 ELSE 0 END                   AS is_mature_90d,

    -- Phân khúc theo luật
    CASE
        WHEN s.frequency IS NULL                         THEN '5. No completed order'
        WHEN s.frequency >= 2                            THEN '1. Repeat Buyers'
        WHEN s.monetary >= (SELECT p80 FROM p80)         THEN '2. One-time High-Value'
        -- chia theo mức chi tiêu (không theo ngày) để lọc theo năm vẫn có ý nghĩa
        WHEN s.monetary >= (SELECT p50 FROM p80)         THEN '3. One-time Mid-Value'
        ELSE                                                  '4. One-time Low-Value'
    END AS customer_segment
FROM all_cust a
LEFT JOIN stats s ON a.customer_unique_id = s.customer_unique_id
LEFT JOIN d fo    ON a.customer_unique_id = fo.customer_unique_id AND fo.rn_first = 1
WHERE a.rn = 1;
GO

-- Kiểm tra: mỗi khách đúng 1 dòng -> 2 số phải bằng nhau
-- SELECT COUNT(*), COUNT(DISTINCT customer_unique_id) FROM v2_dim_customer;
-- Phân khúc mong đợi (khách | %):
--   1. Repeat Buyers 2,414 | 3.0%   2. One-time High-Value 14,894 | 18.4%
--   3. One-time Mid-Value 23,567 | 29.1%   4. One-time Low-Value 40,131 | 49.5%
-- SELECT customer_segment, COUNT(*) FROM v2_dim_customer GROUP BY customer_segment ORDER BY 1;


/* ---------------------------------------------------------------------
   VIEW 4: v2_fact_payments — giữ logic WHERE EXISTS hay của bản cũ
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW v2_fact_payments AS
SELECT p.order_id, p.payment_sequential, p.payment_type,
       p.payment_installments, p.payment_value
FROM olist_order_payments_dataset p
WHERE EXISTS (SELECT 1 FROM v2_fact_orders o WHERE o.order_id = p.order_id);
GO
