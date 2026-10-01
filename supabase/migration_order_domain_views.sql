-- Apply after migration_order_analytics.sql.
-- The physical table names remain stable for existing RPCs and the Spring bridge;
-- these comments, policies, and views make the order domain explicit to new code.
BEGIN;

COMMENT ON TABLE public.order_boards IS
  'A Kanban board belonging to one stock. Each board has its own imported menu and orders.';
COMMENT ON TABLE public.order_catalog_items IS
  'Physical storage for a board menu item: one stock product imported with the price used by that Kanban. Prefer order_board_menu_items for reads in new code.';
COMMENT ON TABLE public.order_item_presets IS
  'Saved selection of stock products and prices that can be imported into a board menu.';
COMMENT ON TABLE public.order_item_preset_items IS
  'One product and price inside an order item preset.';
COMMENT ON TABLE public.order_sales IS
  'Physical storage for an order ticket. The name is retained for compatibility; one row is a customer order, not an accounting sale.';
COMMENT ON TABLE public.order_sale_items IS
  'Immutable snapshot of the products, quantities, and unit prices selected in an order ticket.';

DROP POLICY IF EXISTS order_boards_owner_read ON public.order_boards;
CREATE POLICY order_boards_owner_read ON public.order_boards
  FOR SELECT TO authenticated USING (public.owns_stock(stock_id));

DROP POLICY IF EXISTS order_board_menu_items_owner_read ON public.order_catalog_items;
CREATE POLICY order_board_menu_items_owner_read ON public.order_catalog_items
  FOR SELECT TO authenticated USING (public.owns_stock(stock_id));

DROP POLICY IF EXISTS order_item_presets_owner_read ON public.order_item_presets;
CREATE POLICY order_item_presets_owner_read ON public.order_item_presets
  FOR SELECT TO authenticated USING (public.owns_stock(stock_id));

DROP POLICY IF EXISTS order_item_preset_items_owner_read ON public.order_item_preset_items;
CREATE POLICY order_item_preset_items_owner_read ON public.order_item_preset_items
  FOR SELECT TO authenticated USING (
    EXISTS (
      SELECT 1 FROM public.order_item_presets preset
      WHERE preset.id = public.order_item_preset_items.preset_id AND public.owns_stock(preset.stock_id)
    )
  );

DROP POLICY IF EXISTS order_ticket_items_owner_read ON public.order_sale_items;
CREATE POLICY order_ticket_items_owner_read ON public.order_sale_items
  FOR SELECT TO authenticated USING (
    EXISTS (
      SELECT 1 FROM public.order_sales ticket
      WHERE ticket.id = public.order_sale_items.order_id AND public.owns_stock(ticket.stock_id)
    )
  );

REVOKE ALL ON public.order_boards, public.order_catalog_items, public.order_item_presets,
  public.order_item_preset_items, public.order_sale_items FROM PUBLIC, anon;
GRANT SELECT ON public.order_boards, public.order_catalog_items, public.order_item_presets,
  public.order_item_preset_items, public.order_sale_items TO authenticated;

CREATE OR REPLACE VIEW public.order_board_menu_items WITH (security_invoker = true) AS
  SELECT
    item.id AS menu_item_id,
    item.stock_id,
    item.board_id,
    item.product_id,
    product.sku AS product_unique_code,
    product.name AS product_name,
    product.is_kit AS product_is_recipe,
    item.price AS configured_price,
    item.imported_at
  FROM public.order_catalog_items item
  JOIN public.products product ON product.id = item.product_id;
COMMENT ON VIEW public.order_board_menu_items IS
  'Semantic read model for the products and configured prices available in one Kanban board.';

CREATE OR REPLACE VIEW public.order_tickets WITH (security_invoker = true) AS
  SELECT
    ticket.id AS order_id,
    ticket.stock_id,
    ticket.board_id,
    board.name AS board_name,
    ticket.number AS order_number,
    ticket.customer,
    ticket.note,
    ticket.status,
    ticket.suggested_total,
    ticket.final_total,
    ticket.paid,
    ticket.inventory_operation_id,
    ticket.created_at,
    ticket.updated_at,
    ticket.finished_at
  FROM public.order_sales ticket
  JOIN public.order_boards board ON board.id = ticket.board_id;
COMMENT ON VIEW public.order_tickets IS
  'Semantic read model for customer orders. It preserves prices and status of each order ticket.';

CREATE OR REPLACE VIEW public.order_ticket_items WITH (security_invoker = true) AS
  SELECT
    item.id AS order_item_id,
    item.order_id,
    ticket.stock_id,
    ticket.board_id,
    item.catalog_item_id AS menu_item_id,
    item.product_id,
    item.product_name,
    item.quantity,
    item.unit_price,
    ticket.created_at AS order_created_at
  FROM public.order_sale_items item
  JOIN public.order_sales ticket ON ticket.id = item.order_id;
COMMENT ON VIEW public.order_ticket_items IS
  'Semantic read model for immutable item snapshots inside customer orders.';

REVOKE ALL ON public.order_board_menu_items, public.order_tickets, public.order_ticket_items FROM PUBLIC, anon;
GRANT SELECT ON public.order_board_menu_items, public.order_tickets, public.order_ticket_items TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
