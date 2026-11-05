-- Enables deleting one saved order-item preset from the import dialog.
BEGIN;

CREATE OR REPLACE FUNCTION public.order_presets_delete(
  p_stock_id uuid,
  p_preset_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE deleted_id uuid;
BEGIN
  PERFORM public.assert_stock(p_stock_id);

  DELETE FROM public.order_item_presets
  WHERE id = p_preset_id AND stock_id = p_stock_id
  RETURNING id INTO deleted_id;

  IF deleted_id IS NULL THEN
    RAISE EXCEPTION 'Preset não encontrado neste estoque.' USING ERRCODE = 'P0002';
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.order_presets_delete(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_presets_delete(uuid, uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
