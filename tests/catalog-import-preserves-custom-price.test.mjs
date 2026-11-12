import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';

const stock = '20000000-0000-0000-0000-000000000001';
const sourceStock = '20000000-0000-0000-0000-000000000002';
const board = '40000000-0000-0000-0000-000000000001';
const customProduct = '30000000-0000-0000-0000-000000000001';
const newProduct = '30000000-0000-0000-0000-000000000002';
const db = await PGlite.create();

try {
  await db.exec(`
    CREATE TABLE public.stocks(id uuid PRIMARY KEY);
    CREATE TABLE public.order_boards(id uuid PRIMARY KEY, stock_id uuid NOT NULL);
    CREATE TABLE public.products(id uuid PRIMARY KEY, stock_id uuid NOT NULL, active boolean NOT NULL DEFAULT true);
    CREATE TABLE public.order_catalog_items(
      id uuid PRIMARY KEY DEFAULT md5(random()::text)::uuid,
      stock_id uuid NOT NULL, board_id uuid NOT NULL, product_id uuid NOT NULL,
      price numeric NOT NULL, unit_cost numeric, imported_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE(board_id,product_id)
    );
    CREATE FUNCTION public.assert_stock(p_stock_id uuid) RETURNS void
      LANGUAGE plpgsql AS $$ BEGIN RETURN; END $$;
    CREATE FUNCTION public.orders_catalog_board(p_stock_id uuid,p_board_id uuid) RETURNS jsonb
      LANGUAGE sql AS $$ SELECT coalesce(jsonb_agg(jsonb_build_object('id',c.id,'price',c.price)), '[]'::jsonb)
        FROM public.order_catalog_items c WHERE c.stock_id=p_stock_id AND c.board_id=p_board_id $$;
    INSERT INTO public.stocks VALUES ('${stock}'),('${sourceStock}');
    INSERT INTO public.order_boards VALUES ('${board}','${stock}');
    INSERT INTO public.products(id,stock_id) VALUES ('${customProduct}','${sourceStock}'),('${newProduct}','${sourceStock}');
  `);

  const oldMigration = await readFile(new URL('../supabase/migration_order_import_product_id_ambiguity_fix.sql', import.meta.url), 'utf8');
  await db.exec(oldMigration);
  const migration = await readFile(new URL('../supabase/migration_order_catalog_custom_price_protection.sql', import.meta.url), 'utf8');
  await db.exec(migration);

  await db.query('SELECT public.orders_import_catalog_board($1,$2,$3::jsonb)', [stock, board,
    JSON.stringify([{ sourceProductId: customProduct, sourceStockId: sourceStock, price: 10.25 }])]);

  await db.query('SELECT public.orders_import_catalog_board($1,$2,$3::jsonb) AS data', [stock, board,
    JSON.stringify([
      { sourceProductId: customProduct, sourceStockId: sourceStock, price: 14.50 },
      { sourceProductId: newProduct, sourceStockId: sourceStock, price: 7.75 },
    ])]);
  const rows = (await db.query('SELECT product_id,price FROM public.order_catalog_items WHERE board_id=$1', [board])).rows;
  const byProduct = new Map(rows.map(row => [row.product_id, Number(row.price)]));
  assert.equal(byProduct.get(customProduct), 10.25, 'reimporting other items must keep the existing custom sale price');
  assert.equal(byProduct.get(newProduct), 7.75, 'a new product must still use its selected sale price');

  await db.query('SELECT public.orders_import_catalog_board($1,$2,$3::jsonb)', [stock, board,
    JSON.stringify([{ sourceProductId: customProduct, sourceStockId: sourceStock, price: 11.20, overwritePrice: true }])]);
  const changed = (await db.query('SELECT price FROM public.order_catalog_items WHERE board_id=$1 AND product_id=$2', [board, customProduct])).rows[0];
  assert.equal(Number(changed.price), 11.20, 'an explicit price edit must still update the catalog');

  console.log('PASS catalog import preserves existing prices unless explicitly edited');
} finally {
  await db.close();
}
