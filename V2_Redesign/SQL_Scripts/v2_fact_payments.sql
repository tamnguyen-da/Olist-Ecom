/* ---------------------------------------------------------------------
   VIEW 4: v2_fact_payments — giữ logic WHERE EXISTS hay của bản cũ
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW v2_fact_payments AS
SELECT p.order_id, p.payment_sequential, p.payment_type,
       p.payment_installments, p.payment_value
FROM olist_order_payments_dataset p
WHERE EXISTS (SELECT 1 FROM v2_fact_orders o WHERE o.order_id = p.order_id);
GO
