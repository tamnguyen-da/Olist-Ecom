# Olist E-Commerce: Growth and Customer Retention

**Question:** Olist is growing fast. Do its customers come back?

**Short answer:** No. From January 2017 to June 2018, 97% of revenue came from first-time buyers, and 98% of customers did not return within 90 days.

**Tools:** SQL Server (T-SQL views) · Power BI (star schema, DAX) · Python (independent checks)

> Currency is Brazilian Real (R$). All figures cover **delivered orders, 1 Jan 2017 to 30 Jun 2018**.

---

## Key findings

| # | Finding | Evidence |
|---|---|---|
| 1 | Growth comes from order volume | Jan–Jun 2018 revenue is up 185% on Jan–Jun 2017. Orders are up 189%, while average order value is down 1.5%. The 2017 base is low |
| 2 | Growth slowed in 2018 | Monthly revenue fell 11%, from R$ 1.13M in April to R$ 1.01M in June |
| 3 | Revenue depends on new customers | 97% of revenue comes from a customer's first order |
| 4 | Few customers return | 2.4% order again within 90 days, for both 2017 and 2018 first-time buyers. No monthly cohort has more than 0.72% of its customers back in any one of the six following months |
| 5 | A small group carries revenue | One-time High-Value customers are 18% of customers and 49% of revenue |
| 6 | Late delivery is not a clear driver | 2.1% return after a late first order vs 2.4% on time (z = -1.5, not significant). The 2017 cohort alone shows a significant gap; 2018 does not |

### Recommendation

Test a second-order offer for high-value first-time buyers as an A/B test, with the **90-day repeat rate** (baseline 2.4%) as the main KPI. Delivery delay is worth further testing, but the data does not support it as the main cause.

### Limitations

- The data is observational: these are associations, not proof of cause.
- "High-Value" is defined as the top 20% of customer spend, so a high revenue share is partly built in.
- 48% of repeat orders within 90 days were placed on the same day as the first. They may be split baskets, so the median days to the second order (29) excludes them.
- The lifetime repeat rate (3.0%) should not be compared between years, because later customers have had less time to return.
- Customers who first bought in 2016 are treated as new in 2017. The effect is very small.

---

## Report pages

| Page | What it answers | Main visuals |
|---|---|---|
| Executive Overview | Where does revenue come from? | KPIs with YoY and MoM, monthly revenue and AOV, top categories, top states, new vs returning revenue |
| Customer Retention | Do customers come back? | Retention KPIs, segments, first-order delivery, orders per customer, monthly cohorts |

The Overview slicers filter by **order date**. The Retention page filters by **first purchase year**, so each customer belongs to exactly one year and later purchases stay counted.

<!-- Add current screenshots here, for example:
![Executive Overview](Dashboard_Image/Overview_v2.png)
![Customer Retention](Dashboard_Image/Retention_v2.png)
-->

---

## Data model

```
dim_date ──1:*── fact_orders ──*:1── dim_customers
   │                  │
   │                  └──1:*── fact_payments
   └──1:*── fact_order_items
```

| Table | SQL view | Grain |
|---|---|---|
| fact_orders | `v2_fact_orders` | One row per order |
| fact_order_items | `v2_fact_order_items` | One row per order item |
| fact_payments | `v2_fact_payments` | One row per payment |
| dim_customers | `v2_dim_customer` | One row per unique customer |
| dim_date | DAX calculated table | One row per day |

All relationships filter in one direction.

### Design decisions

- **No fan-out:** items and payments are aggregated to order level before joining.
- **Real customer key:** `customer_unique_id`, because `customer_id` changes with every order.
- **Delivered only:** an order counts when its status is delivered and it has a delivery date.
- **Stable order sequence:** `ROW_NUMBER()` ordered by timestamp **and** `order_id`, so New/Returning does not change between refreshes.
- **Fair repeat rate:** only customers with at least 90 days of history, all measured over the same 90-day window.
- **Rule-based segments:** by spend and repeat purchase, not recency, so they stay meaningful when filtered by year.

| Segment | Rule |
|---|---|
| Repeat Buyers | 2 or more delivered orders |
| One-time High-Value | One order, spend in the top 20% |
| One-time Mid-Value | One order, spend between the median and the top 20% |
| One-time Low-Value | One order, spend below the median |

### Measures

Measures are grouped in four layers: **Base** (sums and counts), **Ratios**, **Time** (MoM and YoY) and **Display** (titles, labels, notes). Display measures mainly build text from the other layers.

---

## Validation

Figures were recomputed in Python from the raw CSV files and compared with Power BI. These matched:

- total and yearly revenue, orders, customers and average order value
- monthly revenue, orders and new-buyer share (18 months)
- cohort retention (87 cells)
- segment counts and revenue shares, overall and by first purchase year
- 90-day repeat rate

Known difference: state totals use each customer's latest address, so a few orders are assigned to a different state than at purchase time.

---

## How to run

1. Download the [Olist Brazilian E-Commerce dataset](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) and load the CSV files into a SQL Server database named `Olist`.
2. Run `V2_Redesign/SQL_Scripts/Olist-views-v2.sql`.
3. Open the `.pbix` file. To refresh, change the server name in Transform data > Data source settings.

The imported data is stored in the `.pbix`, so the report opens without a database.

## Repository

| Path | Content |
|---|---|
| `PowerBI_Report/` | Power BI report |
| `V2_Redesign/SQL_Scripts/` | Current SQL views (`Olist-views-v2.sql` creates all of them) |
| `SQL_Scripts/v2_fact_orders.sql` | Order fact view on its own |
| `SQL_Scripts/Olist-fact-views.sql`, `Python_Scripts/` | First version of the project (K-Means segmentation), kept for reference |

Data source: Olist, via Kaggle. Check the dataset page for its licence before reusing the data.
