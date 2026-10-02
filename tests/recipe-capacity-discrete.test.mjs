import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';

const stock = '20000000-0000-0000-0000-000000000501';
const kit = '30000000-0000-0000-0000-000000000501';
const component = '40000000-0000-0000-0000-000000000501';
const db = await PGlite.create();

function functionDdl(source, signature) {
  const start = source.indexOf(signature);
  assert.notEqual(start, -1, `Missing ${signature}`);
  const end = source.indexOf('END $$;', start);
  assert.notEqual(end, -1, `Unterminated ${signature}`);
  return source.slice(start, end + 'END $$;'.length);
}

try {
  await db.exec(`
    CREATE TABLE public.stocks(id uuid PRIMARY KEY,user_id uuid NOT NULL);
    CREATE TABLE public.products(
      id uuid PRIMARY KEY,stock_id uuid NOT NULL,name text NOT NULL,is_kit boolean NOT NULL,
      content_quantity numeric NOT NULL,content_unit text NOT NULL,active boolean NOT NULL DEFAULT true
    );
    CREATE TABLE public.kit_products(
      id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,kit_id uuid NOT NULL,product_id uuid NOT NULL,
      quantity numeric NOT NULL,unit text NOT NULL
    );
    CREATE TABLE public.stock_lots(id uuid PRIMARY KEY,product_id uuid NOT NULL,quantity_remaining numeric NOT NULL);
    CREATE FUNCTION public.assert_stock(p_stock_id uuid) RETURNS void LANGUAGE plpgsql AS $$
      BEGIN RETURN; END
    $$;
    CREATE FUNCTION public.content_base(p_quantity numeric,p_unit text) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
      SELECT p_quantity * CASE WHEN p_unit IN ('l','kg') THEN 1000 ELSE 1 END
    $$;
    CREATE FUNCTION public.required_base(p_content_quantity numeric,p_content_unit text,p_quantity numeric,p_unit text)
      RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
        SELECT CASE WHEN p_unit='un' THEN p_quantity*public.content_base(p_content_quantity,p_content_unit)
          WHEN p_unit IN ('l','kg') THEN p_quantity*1000 ELSE p_quantity END
      $$;
    CREATE FUNCTION public.portion_factor(p_content_quantity numeric,p_content_unit text,p_quantity numeric,p_unit text)
      RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
        SELECT public.required_base(p_content_quantity,p_content_unit,p_quantity,p_unit)
          / public.content_base(p_content_quantity,p_content_unit)
      $$;
    CREATE FUNCTION public.can_produce_kit(p_stock_id uuid,p_kit_id uuid,p_quantity numeric,p_unit text)
      RETURNS boolean LANGUAGE plpgsql STABLE AS $$
      DECLARE requirement record; available numeric;
      BEGIN
        FOR requirement IN SELECT * FROM public.production_requirements(p_stock_id,p_kit_id,p_quantity,p_unit) LOOP
          SELECT coalesce(sum(l.quantity_remaining),0) INTO available FROM public.stock_lots l
          WHERE l.product_id=requirement.product_id;
          IF available < public.required_base(1,'un',requirement.quantity,requirement.unit) THEN RETURN false; END IF;
        END LOOP;
        RETURN true;
      EXCEPTION WHEN check_violation OR invalid_parameter_value THEN RETURN false;
      END
    $$;
    INSERT INTO public.stocks VALUES('${stock}','10000000-0000-0000-0000-000000000501');
    INSERT INTO public.products VALUES
      ('${kit}','${stock}','Receita de teste',true,100,'g',true),
      ('${component}','${stock}','Unidade indivisível',false,1,'un',true);
    INSERT INTO public.kit_products(kit_id,product_id,quantity,unit) VALUES('${kit}','${component}',3,'un');
    INSERT INTO public.stock_lots(id,product_id,quantity_remaining)
      VALUES('50000000-0000-0000-0000-000000000501','${component}',4);
  `);

  const stockSource = await readFile(new URL('../../sirius-cosmical-stock2/supabase/migration_recipe_production_quantization.sql', import.meta.url), 'utf8');
  const capacitySource = await readFile(new URL('../../sirius-cosmical-stock2/supabase/migration_recipe_capacity_discrete.sql', import.meta.url), 'utf8');
  await db.exec(functionDdl(stockSource, 'CREATE OR REPLACE FUNCTION public.production_requirements('));
  await db.exec(functionDdl(stockSource, 'CREATE OR REPLACE FUNCTION public.recipe_production_options('));
  await db.exec(functionDdl(capacitySource, 'CREATE OR REPLACE FUNCTION public.estimate_kit_capacity('));

  const options = (await db.query(
    'SELECT public.recipe_production_options($1,$2,150,\'g\') AS options', [stock, kit],
  )).rows[0].options;
  assert.equal(options.is_exact, false);
  assert.equal(Number(options.lower.quantity), 133.333333);
  assert.equal(Number(options.lower.components[0].quantity), 4);
  assert.equal(Number(options.upper.quantity), 166.666667);
  assert.equal(Number(options.upper.components[0].quantity), 5);

  const capacity = (await db.query(
    'SELECT whole_units,max_base_quantity,base_unit FROM public.estimate_kit_capacity($1,$2)', [stock, kit],
  )).rows[0];
  assert.equal(Number(capacity.max_base_quantity), 133.333333);
  assert.equal(capacity.base_unit, 'g');
  console.log('OK: 3 unidades por 100 g sugere passos de 133,333333 g e 166,666667 g; capacidade respeita o estoque indivisível.');
} finally {
  await db.close();
}


