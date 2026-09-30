# Acompanhamento de Pedidos

React + Vite para acompanhar pedidos e vender produtos ou kits do Estoque Pro.
Esta branch `main` é o monólito: o navegador usa o mesmo Supabase do projeto
`sirius-cosmical-stock2`, com a chave pública, Auth, PostgREST e RPCs SQL.
Não depende dos serviços Spring nas portas 8080/8086. A branch `front`
preserva o frontend HTTP anterior e seu contrato `API_CONTRACT.md`.

## Configuração

1. No projeto Supabase do Estoque Pro, execute
   [supabase/orders_monolith.sql](supabase/orders_monolith.sql) pelo SQL Editor
   com o proprietário do banco. O script é reaplicável, cria as tabelas de
   pedidos se faltarem e instala as funções transacionais do monólito.
   Não execute `schema.sql` do Estoque sobre uma base existente.
   Se as listas de produtos do Estoque ainda estiverem vazias, aplique antes
   `sirius-cosmical-stock2/supabase/repair_owns_stock_claims.sql`.
2. Em seguida, execute
   [supabase/migration_order_boards.sql](supabase/migration_order_boards.sql)
   no mesmo banco. Ela cria o kanban padrão **Geral**, transfere para ele os
   pedidos e itens já existentes e instala o catálogo separado por kanban,
   presets e atualizações Realtime.
3. Copie `.env.example` para `.env.local` e use a **mesma**
   `VITE_SUPABASE_URL` e chave pública/anon do monólito Estoque. A
   configuração local deste checkout já foi copiada da instalação do Estoque.
   O arquivo `.env.local` é ignorado pelo Git. Nunca use a senha do Postgres
   nem uma chave `service_role` em `VITE_`.
4. Instale as dependências e inicie:

```bash
pnpm install
pnpm dev
```

A aplicação abre em `http://localhost:5173`. Entre com a mesma conta do
Estoque Pro; seus estoques aparecem no seletor. Se a conta não tiver estoque,
crie um ali ou no Estoque Pro. Na primeira importação, selecione produtos/kits
ativos e confirme os preços; o valor sugerido vem do produto/kit ou próximo
lote. Reimportar atualiza o preço sem duplicar o produto.

Cada estoque pode ter vários kanbans, nomeados por dia, turno ou equipe. Cada
kanban tem seu próprio catálogo importado e seus pedidos. Presets guardam uma
seleção de produtos e seus preços para preencher rapidamente a próxima
importação; eles podem ser usados em qualquer kanban do mesmo estoque.

Pedidos guardam o nome e preço unitário no momento da criação. Concluir um
pedido chama `decrement_inventory` dentro da **mesma transação** que atualiza
o status, com referência `pedido:<id>:finalizado`. Se o saldo for insuficiente,
ambas as alterações são revertidas. Cada item do pedido baixa unidades
inteiras do produto/kit; kits precisam estar produzidos no estoque, como no
Estoque Pro. A autenticação e o controle de acesso são por proprietário de
estoque. O navegador não recebe permissão direta nas tabelas de pedidos:
as funções SQL verificam `assert_stock`.

O quadro recebe mudanças por Supabase Realtime e consulta novamente a cada
10 segundos enquanto a aba está visível. Um aviso destacado mostra quantos
pedidos aguardam, e novos cards ficam realçados por dois minutos. O tempo
desde a criação é recalculado a cada minuto. No
celular, as etapas aparecem em abas e o botão de criar pedido fica acessível
na parte inferior. O tema Claro, Escuro ou Neon pode ser escolhido na interface
e permanece salvo neste navegador.

Pedidos podem voltar de **Em preparo** para **Aguardando**, e de **Cancelados**
para **Aguardando**. Depois de **Finalizado**, o status não volta: a baixa de
estoque já foi registrada. Para habilitar a nova transição em um Supabase onde
o aplicativo já estava instalado, execute novamente
[`supabase/orders_monolith.sql`](supabase/orders_monolith.sql) no SQL Editor
antes de publicar este frontend. O script é reaplicável.

## Compatibilidade com a branch HTTP

A migração preserva os pedidos existentes no kanban **Geral**. As rotas HTTP
legadas da API Estoque continuam lendo e gravando nesse kanban; novos quadros
e presets são usados pelo monólito desta branch. Se o banco ainda não tiver a
ponte Spring, aplique primeiro `Estoque/database/migration_orders_bridge.sql`
e depois `supabase/migration_order_boards.sql`. A role `stock_api` recebe apenas
leitura dos kanbans do próprio estoque por RLS. A branch `front` continua
exigindo as APIs em `localhost:8086` e na porta 8080; ela não é necessária
para executar a `main`.

## Publicar e verificar

No Vercel, configure `VITE_SUPABASE_URL` e
`VITE_SUPABASE_PUBLISHABLE_KEY` (ou `VITE_SUPABASE_ANON_KEY`) com os valores
públicos do Estoque Pro e publique a branch `main`. Cadastre a URL do front
nos Redirect URLs do Supabase Auth se usar confirmação de cadastro.

```bash
pnpm test
pnpm run test:stock
pnpm build
```

O teste usa PostgreSQL em memória (PGlite) para validar importação idempotente,
fotografia de preços, isolamento por usuário e baixa única/atômica. O banco
Supabase remoto não é alterado pelos testes. `test:stock` requer os projetos
`sirius-cosmical-stock2` e `Estoque` como irmãos deste diretório para
confirmar a baixa FIFO e a compatibilidade com a migração Spring.
Após aplicar o SQL remoto, valide
login, importação, criação e finalização de um pedido num estoque de teste.
