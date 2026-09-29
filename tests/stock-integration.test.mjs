import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';

// Cross-project integration: keep both projects side by side, or set
// STOCK_SCHEMA_FILE to the absolute path of the Estoque schema.sql.
const stockSchema = process.env.STOCK_SCHEMA_FILE
  ? await readFile(process.env.STOCK_SCHEMA_FILE, 'utf8')
  : await readFile(new URL('../../sirius-cosmical-stock2/supabase/schema.sql', import.meta.url), 'utf8');
const ordersSchema = await readFile(new URL('../supabase/orders_monolith.sql', import.meta.url), 'utf8');
const jdbcSchema = await readFile(new URL('../../sirius-cosmical-stock2/supabase/migration_stock_api_jdbc.sql', import.meta.url), 'utf8');
const springOrdersSchema = await readFile(new URL('../../Estoque/database/migration_orders_bridge.sql', import.meta.url), 'utf8');
const user = '10000000-0000-0000-0000-000000000401';
const stock = '20000000-0000-0000-0000-000000000401';
const product = '30000000-0000-0000-0000-000000000401';
const db = await PGlite.create();

try {
  await db.exec(`
    CREATE ROLE anon NOLOGIN;
    CREATE ROLE authenticated NOLOGIN;
    CREATE ROLE service_role NOLOGIN BYPASSRLS;
    CREATE SCHEMA auth;
    CREATE TABLE auth.users(id uuid PRIMARY KEY,email text);
    CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
      SELECT coalesce(nullif(current_setting('request.jwt.claim.sub',true),''),
        nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid
    $$;
    GRANT USAGE ON SCHEMA public,auth TO anon,authenticated,service_role;
    GRANT EXECUTE ON FUNCTION auth.uid() TO anon,authenticated,service_role;
  `);
  await db.exec(stockSchema);
  await db.exec(ordersSchema);
  // Future Spring cutover can grant the JDBC role on the same tables without
  // dropping or renaming any orders created by this monolith.
  await db.exec(jdbcSchema);
  await db.exec(springOrdersSchema);
  await db.query('INSERT INTO auth.users(id,email) VALUES ($1,$2)', [user, 'owner@example.invalid']);
  await db.query('INSERT INTO public.stocks(id,user_id,name) VALUES ($1,$2,$3)',
    [stock, user, 'Estoque teste']);
  await db.query('INSERT INTO public.products(id,stock_id,name,sku) VALUES ($1,$2,$3,$4)',
    [product, stock, 'Coca 2L', 'COCA']);

  await db.exec('SET ROLE authenticated');
  await db.query("SELECT set_config('request.jwt.claims',$1,false)",
    [JSON.stringify({ sub: user, role: 'authenticated' })]);
  await db.query('SELECT public.receive_lots($1,$2,$3::jsonb)', [stock, 'TESTE-ENTRADA',
    JSON.stringify({ items: [{ product_id: product, code: 'LOTE-TESTE',
      quantity: 3, unit_cost: 10, sale_price: 15 }] })]);
  const imported = (await db.query('SELECT public.orders_import_catalog($1,$2::jsonb) AS data',
    [stock, JSON.stringify([{ sourceProductId: product, price: 15 }])])).rows[0].data[0];
  const order = (await db.query('SELECT public.orders_create($1,$2::jsonb) AS data',
    [stock, JSON.stringify({ customer: 'Mesa 1', note: '', items: [
      { productId: imported.id, quantity: 2 }], finalTotal: 30, paid: 30 })])).rows[0].data;
  await db.query('SELECT public.orders_change_status($1,$2,$3)', [stock, order.id, 'preparing']);
  await db.query('SELECT public.orders_change_status($1,$2,$3)', [stock, order.id, 'finished']);
  const lot = (await db.query('SELECT quantity_remaining FROM public.lot_details WHERE product_id=$1',
    [product])).rows[0];
  assert.equal(Number(lot.quantity_remaining), 1);
  const movements = (await db.query(
    "SELECT count(*)::int AS n FROM public.movement_details WHERE stock_id=$1 AND kind='OUT'", [stock]
  )).rows[0];
  assert.equal(movements.n, 1);
  console.log('OK: schema real do Estoque + pedido concluído + baixa FIFO.');
} finally {
  await db.close();
}
