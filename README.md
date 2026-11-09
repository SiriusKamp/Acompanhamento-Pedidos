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
   Execute também [supabase/migration_order_preset_delete.sql](supabase/migration_order_preset_delete.sql)
   para habilitar a exclusão segura de presets na tela de importação.
3. Para habilitar custo, lucro e recomendações por pedido, execute também
   [supabase/migration_order_analytics.sql](supabase/migration_order_analytics.sql).
   Ela vincula pedidos finalizados aos movimentos FIFO e cria as consultas
   seguras do dashboard estratégico.
4. Em seguida, execute [supabase/migration_order_sale_settlement.sql](supabase/migration_order_sale_settlement.sql).
   Ela finaliza pedidos mesmo em caso de falta de saldo, baixa os itens que
   puderem ser baixados até zero, registra somente a diferença pendente, congela
   custo, preço e margem por item e permite custo unitário manual no catálogo.
   Em bancos que já receberam essa migration antes dos índices de liquidação,
   execute também [supabase/migration_order_sale_settlement_indexes.sql](supabase/migration_order_sale_settlement_indexes.sql).
5. Execute [supabase/migration_order_sale_partial_settlement.sql](supabase/migration_order_sale_partial_settlement.sql)
   para instalar a correção incremental de baixa parcial e snapshots em bancos
   existentes. Ela também pode ser executada após a migration principal em uma
   instalação nova.
6. Execute [supabase/migration_order_multi_stock_catalog.sql](supabase/migration_order_multi_stock_catalog.sql)
   para permitir que um kanban importe itens de todos os estoques da conta.
   Cada linha do pedido guarda o estoque de origem; ao finalizar, a baixa e o
   custo FIFO são registrados nesse estoque.
7. Execute [supabase/migration_order_import_product_id_ambiguity_fix.sql](supabase/migration_order_import_product_id_ambiguity_fix.sql)
   para manter a variável da função de importação com nome distinto da coluna
   `product_id` e evitar erro de ambiguidade.
8. Execute [supabase/migration_order_preset_id_ambiguity_fix.sql](supabase/migration_order_preset_id_ambiguity_fix.sql)
   para evitar conflito entre a variável local `v_preset_id` e a coluna
   `preset_id` ao salvar presets.
9. Execute [supabase/migration_order_presets_account_scope.sql](supabase/migration_order_presets_account_scope.sql)
   para tornar presets e preços disponíveis em todos os estoques e Kanbans da
   conta. Ela migra os presets existentes, preserva itens e valores e ajusta
   nomes repetidos entre estoques. Execute antes de publicar esta versão.
10. Execute [supabase/migration_order_measurement_and_edit.sql](supabase/migration_order_measurement_and_edit.sql)
   para editar pedidos ainda não finalizados, vender itens por `ml` ou `g`,
   baixar essas medidas do estoque e normalizar quantidades nas análises.
   Pedidos finalizados permanecem bloqueados para proteger o histórico FIFO.
11. Em bancos que já receberam a migration de medidas, execute
   [supabase/migration_order_analytics_output_ambiguity_fix.sql](supabase/migration_order_analytics_output_ambiguity_fix.sql)
   para corrigir a ambiguidade dos parâmetros de saída nas consultas analíticas.
12. Execute [supabase/migration_order_analytics_unit_rankings.sql](supabase/migration_order_analytics_unit_rankings.sql)
   para calcular o ranking “Mais vendidos” pelas quantidades registradas em
   `un`, sem converter embalagens vendidas em unidades para ml/g.
13. Copie `.env.example` para `.env.local` e use a **mesma**
   `VITE_SUPABASE_URL` e chave pública/anon do monólito Estoque. A
   configuração local deste checkout já foi copiada da instalação do Estoque.
   O arquivo `.env.local` é ignorado pelo Git. Nunca use a senha do Postgres
   nem uma chave `service_role` em `VITE_`.
11. Instale as dependências e inicie:

```bash
pnpm install
pnpm dev
```

A aplicação abre em `http://localhost:5173`. Entre com a mesma conta do
Estoque Pro; seus estoques aparecem no seletor. Se a conta não tiver estoque,
crie um ali ou no Estoque Pro. Na primeira importação, selecione produtos/kits
ativos em qualquer estoque da conta e confirme os preços; o valor sugerido vem
do produto/kit ou próximo lote. Reimportar atualiza o preço sem duplicar o item.

Cada estoque pode ter vários kanbans, nomeados por dia, turno ou equipe. Cada
kanban tem seu próprio catálogo importado e seus pedidos. Presets guardam uma
seleção de produtos e seus preços na conta, para preencher rapidamente a
próxima importação em qualquer kanban e estoque da mesma conta. O catálogo
continua separado por kanban; os presets podem ser editados na tela de
importação e excluídos pelo botão de lixeira.

Pedidos guardam o nome, preço e custo unitário manual no momento da criação.
Concluir um pedido sempre atualiza o status. Primeiro o banco tenta uma baixa
FIFO única; se faltar saldo, baixa separadamente os itens disponíveis e registra
os demais como pendência. Cada item do pedido baixa unidades inteiras do
produto/kit; kits precisam estar produzidos no estoque, como no Estoque Pro.
O dashboard mostra baixa parcial, pendências e itens sem custo. O custo FIFO
real prevalece; o custo unitário manual só cobre um item sem baixa rastreável.

O quadro recebe mudanças por Supabase Realtime e consulta novamente a cada
10 segundos enquanto a aba está visível. Um aviso destacado mostra quantos
pedidos aguardam, e novos cards ficam realçados por dois minutos. O tempo
desde a criação é recalculado a cada minuto. No
celular, as etapas aparecem em abas e o botão de criar pedido fica acessível
na parte inferior. O tema Claro, Escuro ou Neon pode ser escolhido na interface
e permanece salvo neste navegador.

A seção **Análises** usa exclusivamente pedidos finalizados. A receita vem do
valor final do pedido e o CMV vem dos lotes FIFO realmente consumidos. Quando
um pedido histórico não tiver baixa vinculável, o dashboard mostra o aviso de
cobertura incompleta em vez de assumir custo zero. Veja
[RUNBOOK_DASHBOARD_ESTRATEGICO.md](RUNBOOK_DASHBOARD_ESTRATEGICO.md) para as
regras de lucro, filtros, recomendações e implantação.

Pedidos podem voltar de **Em preparo** para **Aguardando**, e de **Cancelados**
para **Aguardando**. Depois de **Finalizado**, o status não volta: a baixa de
estoque já foi registrada. Para habilitar a nova transição em um Supabase onde
o aplicativo já estava instalado, execute novamente
[`supabase/orders_monolith.sql`](supabase/orders_monolith.sql) no SQL Editor
antes de publicar este frontend. O script é reaplicável.

## Modo monólito

O projeto não depende de Spring nem de APIs HTTP locais. O navegador usa as
RPCs e tabelas do mesmo Supabase do Estoque Pro. Quando aprovada e aplicada,
`sirius-cosmical-stock2/supabase/migration_monolith_no_rls.sql` desativa RLS
nas tabelas públicas; Storage mantém as regras próprias para os arquivos de
imagem.

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

Os testes usam PostgreSQL em memória (PGlite) para validar importação
idempotente, fotografia de preços, baixa parcial com pendência, snapshots
financeiros e capacidade de receitas com ingredientes indivisíveis. O teste de
capacidade lê as migrations do projeto `sirius-cosmical-stock2`, que precisa
estar como irmão deste diretório. O banco Supabase remoto não é alterado pelos
testes. `test:stock` também requer esse projeto irmão para confirmar a baixa FIFO
no monólito.
Pedidos em andamento podem ser corrigidos pelo botão **Editar** no card,
incluindo itens, quantidades, medidas, pagamento e total final. Produtos com
conteúdo por volume ou peso podem ser vendidos em `ml` ou `g`; o custo FIFO,
a baixa e as análises usam a quantidade medida. Para uma embalagem de 2 L,
por exemplo, o preço sugerido por ml é calculado a partir do preço cadastrado
para a unidade/embalagem. Pedidos já finalizados ficam somente para consulta.

A aba de produtos das análises permite consultar a lista completa, filtrar por
categoria e estoque de origem e ordenar por quantidade, receita, custo, lucro,
margem ou nome.

Após aplicar o SQL remoto, valide login, importação, criação e finalização de
um pedido num estoque de teste.
