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