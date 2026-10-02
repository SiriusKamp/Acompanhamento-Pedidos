-- Allows a kitchen to move a card from "preparing" back to "waiting".
-- Completed orders remain immutable because a stock settlement may exist.
BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.orders_change_status_board_core(uuid,uuid,uuid,text)') IS NULL THEN
    ALTER FUNCTION public.orders_change_status_board(uuid,uuid,uuid,text)
      RENAME TO orders_change_status_board_core;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.orders_change_status_board(
  p_stock_id uuid,p_board_id uuid,p_order_id uuid,p_status text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE previous_status text;
BEGIN
  PERFORM public.assert_stock(p_stock_id);

  IF p_status='waiting' THEN
    SELECT status INTO previous_status FROM public.order_sales
      WHERE id=p_order_id AND stock_id=p_stock_id AND board_id=p_board_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Pedido não encontrado neste kanban.' USING ERRCODE='P0002';
    END IF;
    IF previous_status='preparing' THEN
      UPDATE public.order_sales
      SET status='waiting',updated_at=now()
      WHERE id=p_order_id AND stock_id=p_stock_id AND board_id=p_board_id;
      RETURN public.orders_get_board(p_stock_id,p_board_id,p_order_id);
    END IF;
  END IF;

  RETURN public.orders_change_status_board_core(p_stock_id,p_board_id,p_order_id,p_status);
END $$;

REVOKE ALL ON FUNCTION public.orders_change_status_board_core(uuid,uuid,uuid,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.orders_change_status_board(uuid,uuid,uuid,text) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
