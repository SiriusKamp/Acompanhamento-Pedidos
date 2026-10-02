-- Apply only to Supabase projects where migration_order_sale_settlement.sql
-- was already executed before these indexes were added to its source file.
BEGIN;

CREATE INDEX IF NOT EXISTS order_inventory_settlements_operation
  ON public.order_inventory_settlements(inventory_operation_id)
  WHERE inventory_operation_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS order_inventory_settlements_product
  ON public.order_inventory_settlements(product_id)
  WHERE product_id IS NOT NULL;

NOTIFY pgrst, 'reload schema';
COMMIT;
