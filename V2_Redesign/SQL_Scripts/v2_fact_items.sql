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