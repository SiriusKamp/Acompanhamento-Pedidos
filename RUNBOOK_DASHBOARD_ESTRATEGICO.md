# Runbook — Dashboard estratégico de vendas, custo e produção

## 1. Situação deste documento

Este documento é o plano e a referência de implementação. A primeira versão do
frontend e a migração aditiva `migration_order_analytics.sql` já foram criadas
no projeto. A única ação externa pendente é executar essa migração no SQL
Editor do Supabase antes de publicar o frontend; sem ela, a página mostra uma
mensagem clara de que o dashboard ainda não foi instalado no banco.

Projeto principal da interface:
`C:\Users\sirius.alves\Projetos\Acompanhamento-Pedidos-Front`

Fonte do custo e saldo:
`C:\Users\sirius.alves\Projetos\sirius-cosmical-stock2`

## 2. Resultado esperado

Adicionar ao Acompanhamento de Pedidos uma seção **Análises**, responsiva e
compatível com os temas claro, escuro e neon. A seção deve responder, com dados
rastreáveis:

- Quanto foi vendido, gasto e gerado de lucro em cada período?
- Qual kanban, dia ou equipe gera mais receita e lucro?
- Quais produtos vendem mais em unidades, receita e frequência de pedidos?
- Quais produtos têm maior margem e maior contribuição em reais?
- Quais itens merecem mais produção para evitar ruptura?
- Quais itens vendem bem, mas precisam de revisão de preço ou custo?
- Quais itens têm boa margem, mas pouca saída e podem ser promovidos?
- Quais itens possuem demanda e margem fracas e merecem reavaliação?
- Qual foi o custo e lucro real de cada pedido e de cada item do pedido?

O dashboard não deve usar o custo atual do produto para reescrever o passado.
O custo histórico será o custo FIFO dos lotes realmente consumidos quando o
pedido foi finalizado.

## 3. Decisões de negócio

### 3.1 Momento de reconhecimento da venda

Os indicadores financeiros usam por padrão apenas pedidos **Finalizados**.
Pedidos aguardando e em preparo ainda são operação aberta; cancelados não são
venda. A data financeira é `finished_at`, e não a data de criação.

O dashboard geral pode mostrar, em um cartão separado, o valor potencial dos
pedidos abertos. Esse valor não entra em receita, custo, lucro ou margem.

### 3.2 Receita do pedido

O valor reconhecido como receita é `order_sales.final_total`. O campo `paid`
representa o valor entregue pelo cliente e pode incluir troco; portanto não é
receita.

### 3.3 Custo real

Ao finalizar um pedido, o Estoque cria uma operação com referência:

```text
pedido:<order_id>:finalizado
```

O custo real do pedido é a soma absoluta dos movimentos dessa operação:

```text
CMV = SUM(ABS(inventory_movements.quantity) * cost_per_base)
```

Isso funciona para produtos simples e kits. No kit, o lote produzido já contém
o custo FIFO real dos ingredientes consumidos na produção.

### 3.4 Lucro, margem e markup

Os termos serão exibidos separadamente para evitar ambiguidade:

```text
Lucro bruto = Receita - CMV
Margem bruta (%) = Lucro bruto / Receita * 100
Markup realizado (%) = Lucro bruto / CMV * 100
```

Se a receita ou o custo for zero, a taxa correspondente deve aparecer como
“Não aplicável”, nunca como infinito ou `NaN`.

Taxas, impostos, comissões, frete e despesas fixas ainda não existem no modelo.
Por isso o dashboard deve chamar o resultado de **lucro bruto**, sem sugerir
que seja lucro líquido.

### 3.5 Rateio do valor final entre os produtos

O caixa pode editar o valor final do pedido. Para que os produtos somados
fechem exatamente com o pedido, desconto ou acréscimo será rateado de forma
proporcional ao valor original de cada linha:

```text
valor original da linha = quantidade * preço unitário registrado
receita da linha = final_total * valor original da linha / suggested_total
```

Regras de exceção:

- Pedido gratuito: receita de todas as linhas igual a zero.
- `suggested_total = 0` e `final_total > 0`: ratear pela quantidade de itens.
- A última linha absorve eventual diferença de centavos do arredondamento.
- O custo nunca é rateado: vem dos lotes realmente consumidos pelo produto.

### 3.6 Período e fuso horário

O período será inclusivo no início e exclusivo no fim: `[início, fim)`. A
interface trabalha em `America/Sao_Paulo` e envia timestamps UTC às RPCs.
Assim, “Hoje” não muda de significado conforme o navegador ou o servidor.

### 3.7 Comparação

Todo período selecionado será comparado ao período imediatamente anterior com
a mesma duração. Exemplo: os últimos 7 dias são comparados aos 7 dias
anteriores. Os cartões exibem variação percentual e o valor absoluto usado na
comparação.

Quando o período anterior for zero, exibir “Sem base anterior” em vez de uma
porcentagem enganosa.

## 4. Organização da tela final

Adicionar **Análises** ao menu principal com ícone de gráfico. A página terá um
cabeçalho fixo de filtros e três visões: **Visão geral**, **Produtos** e
**Pedidos**.

### 4.1 Filtros globais

Os mesmos filtros permanecem ao trocar de visão:

- Estoque ativo, reaproveitando o seletor global existente.
- Kanban: todos, um kanban específico ou vários kanbans.
- Período: Hoje, Ontem, 7 dias, 30 dias, Mês atual e Personalizado.
- Comparar com período anterior: ligado por padrão.
- Apenas produtos, apenas kits ou ambos.
- Busca por nome ou código na visão de produtos.

O filtro de kanban deve mostrar nome e quantidade de pedidos finalizados no
período. Seleções serão salvas por usuário e estoque no `localStorage`, sem
interferir no kanban ativo da tela operacional.

### 4.2 Visão geral

#### Faixa de indicadores

1. Pedidos finalizados.
2. Receita realizada.
3. CMV real.
4. Lucro bruto.
5. Margem bruta.
6. Ticket médio.

Cada cartão traz comparação com o período anterior. Receita, CMV e lucro
também exibem uma pequena série temporal para contexto, se houver espaço.

#### Gráfico financeiro por dia

Gráfico combinado:

- Barras: receita e CMV.
- Linha: lucro bruto.
- Alternador de agrupamento: hora, dia, semana ou mês quando compatível com o
  período escolhido.
- Tooltip com pedidos, ticket médio e margem do ponto.

#### Comparação entre kanbans

Tabela e barras horizontais contendo:

- Kanban.
- Pedidos.
- Receita.
- CMV.
- Lucro bruto.
- Margem bruta.
- Ticket médio.
- Participação na receita total.

Ordenação padrão por lucro bruto. O clique em um kanban aplica o filtro global.

#### Mix de produtos

Exibir lado a lado:

- Top 5 por quantidade vendida.
- Top 5 por receita.
- Top 5 por lucro bruto.
- Produtos com margem abaixo da meta.

Quantidade, receita e lucro são rankings diferentes e não devem ser fundidos
em um único “produto mais vendido”.

#### Pareto de contribuição

Gráfico ordenado por lucro bruto acumulado. A curva mostra quais produtos
produzem 80% do lucro do período. Esse painel ajuda a proteger os itens que
realmente sustentam o resultado, mesmo que não liderem em volume.

#### Alertas estratégicos

Cards curtos e explicáveis:

- **Produzir mais**: boa demanda e margem, mas baixa cobertura de estoque.
- **Evitar ruptura**: alta velocidade de venda e estoque abaixo da meta.
- **Revisar preço/custo**: alta demanda e margem abaixo da meta.
- **Promover**: boa margem, disponibilidade e baixa penetração nos pedidos.
- **Reavaliar cardápio**: baixa demanda e margem baixa ou negativa.
- **Dados insuficientes**: produto novo ou período curto demais.

Cada alerta deve dizer o motivo com números, por exemplo: “12 un vendidas,
32% de margem e cobertura estimada de 1,8 dia”. Não usar recomendações opacas.

### 4.3 Visão Produtos

#### Resumo visual

Um diagrama de dispersão organiza os produtos:

- Eixo X: quantidade vendida ou penetração nos pedidos.
- Eixo Y: margem bruta.
- Tamanho da bolha: receita.
- Cor: recomendação estratégica.

Quadrantes:

- Alta demanda + boa margem: **Priorizar produção**.
- Alta demanda + margem baixa: **Revisar preço ou custo**.
- Baixa demanda + boa margem: **Promover e testar posição no cardápio**.
- Baixa demanda + margem baixa: **Reavaliar**.

Os limites “alto/baixo” serão calculados por percentis dentro do conjunto
filtrado, com uma margem mínima configurável. Isso evita usar o mesmo número
fixo para operações de tamanhos diferentes.

#### Tabela estratégica de produtos

Colunas:

- Produto e código único.
- Produto simples ou kit.
- Pedidos que contêm o produto.
- Penetração nos pedidos (%).
- Quantidade vendida.
- Receita rateada.
- CMV FIFO.
- Lucro bruto.
- Margem bruta (%).
- Markup realizado (%).
- Preço médio realizado.
- Desconto/acréscimo médio.
- Estoque em unidades inteiras.
- Velocidade média de venda por dia.
- Cobertura estimada em dias.
- Última venda.
- Tendência contra o período anterior.
- Recomendação e justificativa.

A tabela deve permitir ordenar qualquer métrica relevante e exportar CSV no
mesmo recorte dos filtros.

#### Painel lateral do produto

Ao selecionar um produto, abrir detalhes sem sair do dashboard:

- Evolução de quantidade, receita, custo e lucro.
- Resultado separado por kanban.
- Pedidos recentes que contêm o produto.
- Lotes consumidos e custos unitários do período.
- Estoque atual, velocidade e cobertura.
- Para kits: sugestão de produção e capacidade atual, quando disponível.

### 4.4 Visão Pedidos

Tabela paginada no servidor:

- Número do pedido.
- Kanban.
- Cliente/mesa.
- Data de criação.
- Data de finalização.
- Tempo total até finalizar.
- Quantidade de linhas e itens.
- Receita.
- CMV real.
- Lucro bruto.
- Margem bruta.
- Desconto ou acréscimo sobre o valor sugerido.
- Qualidade do vínculo com o estoque.

Ao expandir um pedido, mostrar cada produto com quantidade, preço registrado,
receita após rateio, custo FIFO, lucro, margem e lotes consumidos. A soma das
linhas deve fechar com os totais do pedido.

## 5. Regras das recomendações

As recomendações são auxiliares de decisão, não comandos automáticos.

### 5.1 Amostra mínima

Classificar como “Dados insuficientes” quando ocorrer qualquer condição:

- Período menor que 7 dias.
- Produto presente em menos de 3 pedidos finalizados.
- Custo histórico incompleto.
- Produto importado há menos tempo que o período analisado, quando essa data
  distorcer a comparação.

### 5.2 Metas configuráveis na interface

- Margem mínima desejada: padrão 20%.
- Cobertura alvo: padrão 7 dias; opções 3, 7, 14 e 30.
- Estoque de segurança: padrão 1 dia de venda média.

Essas preferências podem começar no `localStorage`. Persistência por usuário
no banco fica para uma fase posterior, caso seja realmente necessária.

### 5.3 Velocidade e cobertura

```text
velocidade diária = quantidade vendida / número de dias do período
cobertura = unidades inteiras disponíveis / velocidade diária
sugestão = CEIL(MAX(0, velocidade diária * cobertura alvo
                         + estoque de segurança
                         - unidades disponíveis))
```

Para reduzir distorção, produtos sem venda não recebem cobertura infinita;
aparecem como “Sem consumo no período”. Porções abertas não contam como uma
unidade vendável quando o pedido usa unidade inteira.

### 5.4 Critérios iniciais

- **Produzir mais**: kit, demanda no quartil superior, margem acima da meta e
  cobertura abaixo do alvo.
- **Evitar ruptura**: produto ou kit, demanda acima da mediana e cobertura
  menor que o estoque de segurança.
- **Revisar preço/custo**: demanda acima da mediana e margem abaixo da meta.
- **Promover**: margem acima da meta, demanda abaixo da mediana e estoque com
  cobertura acima do alvo.
- **Reavaliar cardápio**: demanda no quartil inferior e margem abaixo da meta,
  respeitando a amostra mínima.
- **Saudável**: não atende a nenhuma regra de atenção.

“Reavaliar” não significa excluir automaticamente. O painel deve sugerir
investigar preço, posição no cardápio, desperdício ou retirada.

## 6. Fonte de dados confirmada

O modelo atual já fornece:

- `order_boards`: kanban/equipe/dia.
- `order_sales`: pedido, valor sugerido, valor final, pagamento e status.
- `order_sale_items`: quantidade, nome e preço unitário no momento da venda.
- `order_catalog_items`: relação do item vendido com o produto do estoque.
- `inventory_operations`: operação de baixa identificada pela referência do
  pedido.
- `inventory_operation_items`: produto e quantidade solicitados na baixa.
- `inventory_movements`: lotes efetivamente consumidos, quantidade e custo por
  medida base.
- `stock_lots`: custo do lote e saldo atual.
- `products`/`product_catalog`: cadastro, natureza produto/kit e estoque atual.
- `production_runs`: custo real e lote gerado na produção de kits.

O histórico de movimentos é imutável, o que permite auditoria financeira.

## 7. Evolução prevista do banco

Criar futuramente uma migração separada, sugerida como:

```text
supabase/migration_order_analytics.sql
```

Essa migração será reaplicável e executada depois de
`migration_order_boards.sql`.

### 7.1 Ligações necessárias

Adicionar a `order_sales`:

- `finished_at timestamptz null`: instante financeiro da finalização.
- `inventory_operation_id uuid null unique`: ligação direta com a operação
  FIFO criada para o pedido.

Adicionar a `order_sale_items`:

- `product_id uuid null`: snapshot relacional do produto vendido, sem depender
  para sempre do catálogo importado do kanban.

Não adicionar custo corrente ao produto e não copiar custos dos lotes para o
pedido. O movimento de estoque continua sendo a fonte auditável do custo.

### 7.2 Finalização futura

`orders_change_status_board` deve capturar o UUID retornado por
`decrement_inventory`, salvar `inventory_operation_id` e definir `finished_at`
na mesma transação que altera o status para `finished`.

### 7.3 Backfill

Para pedidos finalizados existentes:

1. Localizar a operação por `stock_id` e referência
   `pedido:<order_id>:finalizado`.
2. Preencher `inventory_operation_id`.
3. Usar `inventory_operations.occurred_at` como `finished_at`.
4. Preencher `order_sale_items.product_id` a partir de
   `order_catalog_items.product_id`.
5. Onde não houver vínculo, manter `NULL` e marcar a linha como incompleta.

Não preencher custo ausente com custo atual ou zero. Isso criaria lucro falso.

### 7.4 Índices previstos

- `order_sales(stock_id, finished_at, id) WHERE status = 'finished'`.
- `order_sales(stock_id, board_id, finished_at, id) WHERE status = 'finished'`.
- `order_sale_items(product_id, order_id)`.
- O índice único existente em `(stock_id, reference)` já resolve a ligação
  histórica das operações.

### 7.5 Camada analítica

Criar uma view interna, sem acesso direto do navegador, que produza uma linha
por produto vendido:

```text
order_id, stock_id, board_id, product_id, finished_at,
quantity, listed_revenue, allocated_revenue, actual_cost,
gross_profit, gross_margin, markup, cost_complete
```

Nome sugerido: `order_sale_line_facts`.

A view deve agregar os movimentos dos vários lotes consumidos pelo mesmo item.
Todos os acessos externos ocorrerão por funções `SECURITY DEFINER` que chamam
`assert_stock`, fixam `search_path`, validam intervalo e paginação, revogam
`PUBLIC/anon` e concedem execução somente a `authenticated`.

### 7.6 RPCs previstas

#### `orders_analytics_overview`

Entrada:

```json
{
  "p_stock_id": "uuid",
  "p_board_ids": ["uuid"],
  "p_from": "2026-09-01T03:00:00Z",
  "p_to": "2026-10-01T03:00:00Z",
  "p_timezone": "America/Sao_Paulo"
}
```

Saída:

```json
{
  "summary": {
    "orders": 120,
    "revenue": 7800.00,
    "cost": 3120.00,
    "profit": 4680.00,
    "margin": 60.00,
    "averageTicket": 65.00,
    "openPotential": 420.00
  },
  "previous": {},
  "series": [],
  "boards": [],
  "rankings": {},
  "pareto": [],
  "insights": [],
  "quality": {
    "finishedOrders": 120,
    "costCompleteOrders": 119,
    "coveragePercent": 99.17
  }
}
```

#### `orders_analytics_products`

Recebe os filtros globais, busca, natureza do produto, ordenação, limite e
offset. Retorna totais, linhas de produto, estoque atual, cobertura,
recomendação e total para paginação.

#### `orders_analytics_orders`

Recebe filtros, ordenação, limite e offset. Retorna os pedidos finalizados com
receita, custo, lucro, margem e estado de integridade.

#### `orders_analytics_order_detail`

Recebe estoque e pedido. Retorna linhas rateadas, lotes consumidos e totais de
conferência. Deve rejeitar pedido de outro estoque.

## 8. Qualidade e honestidade dos indicadores

O dashboard deve sempre retornar a cobertura dos custos:

```text
cobertura = pedidos finalizados com custo completo / pedidos finalizados
```

Se a cobertura for menor que 100%:

- Receita total pode continuar sendo mostrada.
- CMV, lucro e margem recebem aviso de dados incompletos.
- Pedidos sem vínculo aparecem na visão Pedidos.
- Recomendações dos produtos afetados ficam como “Dados insuficientes”.
- Nunca tratar custo ausente como zero.

Também devem existir invariantes de conferência:

- Soma da receita das linhas = valor final do pedido.
- Soma do custo das linhas = custo dos movimentos da operação.
- Soma do lucro das linhas = lucro do pedido.
- Soma dos pedidos por kanban = total geral no mesmo filtro.

## 9. Arquitetura prevista do frontend

Evitar ampliar ainda mais `App.tsx`. A implementação deve extrair a nova área:

```text
src/
  pages/
    AnalyticsDashboard.tsx
  components/analytics/
    AnalyticsFilters.tsx
    MetricCard.tsx
    FinancialTrendChart.tsx
    BoardComparison.tsx
    ProductRankings.tsx
    ProductQuadrant.tsx
    ProductStrategyTable.tsx
    ProductDrawer.tsx
    OrderProfitTable.tsx
    OrderProfitDrawer.tsx
    DataQualityNotice.tsx
  hooks/
    useOrderAnalytics.ts
  lib/
    analyticsApi.ts
  types/
    analytics.ts
```

Usar uma biblioteca de gráficos responsiva, preferencialmente Recharts, e
carregar a página de análises com `React.lazy`. Assim o pacote dos gráficos não
atrasa a tela operacional da cozinha.

### 9.1 Atualização dos dados

Quando a página estiver aberta:

- Escutar mudanças de `order_sales` pelo Realtime já configurado.
- Invalidar a consulta ao receber uma finalização no estoque ativo.
- Agrupar eventos próximos com debounce para evitar consultas duplicadas.
- Fazer atualização de segurança a cada 60 segundos enquanto a aba estiver
  visível.
- Exibir horário da última atualização e botão de atualizar.
- Cancelar ou ignorar respostas antigas quando filtros mudarem.

### 9.2 Responsividade

Desktop:

- Filtros em uma barra única.
- KPIs em grade de 3 ou 6 colunas conforme a largura.
- Gráficos em duas colunas.
- Tabelas completas com cabeçalho fixo.

Celular:

- Filtros principais visíveis e filtros avançados em gaveta.
- KPIs em carrossel horizontal com encaixe.
- Gráficos em uma coluna e altura reduzida.
- Tabela de produtos transformada em cards de comparação.
- Detalhes em tela cheia, com ação clara para voltar.

Gráficos não podem depender somente de cor. Devem possuir rótulos, tooltip,
legenda e tabela textual equivalente para acessibilidade.

## 10. Etapas de execução futura

### T01 — Preparar vínculo analítico e data de finalização

**Contexto:** o custo existe nos movimentos FIFO, mas o pedido ainda encontra
a operação pelo texto da referência. A data de finalização também não possui
campo próprio.

**Implementação:** criar a migração, colunas, índices, backfill e alterar a
finalização para gravar operação e instante na mesma transação.

**Aceite:** um pedido novo finalizado possui `finished_at`,
`inventory_operation_id` e `product_id` em todas as linhas; pedidos antigos
recuperáveis são preenchidos sem inventar custo.

### T02 — Construir fatos e validar fechamento financeiro

**Contexto:** cada item pode consumir mais de um lote, e o valor final pode ter
desconto ou acréscimo.

**Implementação:** criar a view interna por linha, rateio determinístico e
flags de qualidade.

**Aceite:** receita, custo e lucro das linhas fecham com cada pedido até o
centavo; um produto consumido em dois lotes soma os dois custos.

### T03 — Implementar RPCs de leitura

**Contexto:** o navegador não deve baixar todo o histórico para agregar em
memória.

**Implementação:** resumo, produtos, pedidos e detalhe; validação de dono,
datas, kanbans, limite, offset e ordenação permitida.

**Aceite:** consultas não expõem outro estoque, filtros retornam totais
coerentes e listas grandes são paginadas no banco.

### T04 — Criar navegação, filtros e estado da página

**Contexto:** a tela atual usa navegação interna no `App.tsx`.

**Implementação:** adicionar Análises, extrair página, filtros persistentes,
estados de carregamento, vazio, erro e dados incompletos.

**Aceite:** trocar de visão preserva filtros; trocar de estoque limpa seleções
incompatíveis; URL ou recarregamento não quebra a tela.

### T05 — Implementar Visão geral

**Contexto:** visão executiva para identificar resultado e mudanças.

**Implementação:** KPIs, tendência, comparação de kanbans, rankings, Pareto e
alertas estratégicos.

**Aceite:** todos os gráficos possuem valor textual conferível e respondem aos
mesmos filtros.

### T06 — Implementar Visão Produtos

**Contexto:** orientar produção, preço, promoção e reavaliação.

**Implementação:** quadrantes, tabela estratégica, estoque, cobertura,
recomendações explicáveis, detalhes e exportação.

**Aceite:** recomendação mostra regra e números; custo ausente bloqueia
conclusões financeiras; sugestão de produção nunca fica negativa.

### T07 — Implementar Visão Pedidos

**Contexto:** permitir auditoria do agregado até lotes e linhas.

**Implementação:** tabela paginada, ordenação e painel detalhado.

**Aceite:** qualquer total do dashboard pode ser rastreado a pedidos, produtos
e movimentos de lote.

### T08 — Realtime, desempenho e experiência responsiva

**Contexto:** o dashboard deve refletir pedidos finalizados sem prejudicar o
kanban da cozinha.

**Implementação:** invalidação por Realtime, fallback, debounce, carregamento
preguiçoso de gráficos e layouts móvel/desktop.

**Aceite:** uma finalização aparece automaticamente; a tela operacional não
recebe aumento significativo no carregamento inicial.

### T09 — Verificação e publicação controlada

**Contexto:** indicadores financeiros errados são piores que a ausência do
dashboard.

**Implementação:** validar fórmulas, segurança, casos extremos, build e
comparação manual com movimentos FIFO antes do deploy.

**Aceite:** todos os cenários da seção seguinte passam e o SQL pode ser
reaplicado sem duplicar objetos ou corromper dados.

## 11. Cenários obrigatórios de validação

1. Pedido de um produto consumido em um único lote.
2. Pedido de um produto atravessando dois lotes com custos diferentes.
3. Pedido de kit produzido com custo herdado dos ingredientes.
4. Pedido com desconto no valor final.
5. Pedido com acréscimo no valor final.
6. Pedido gratuito.
7. Pedido criado num dia e finalizado no dia seguinte.
8. Pedido cancelado, que não deve entrar no financeiro.
9. Dois kanbans no mesmo período, filtrados individualmente e juntos.
10. Produto presente em vários pedidos e kanbans.
11. Produto com custo zero real.
12. Registro histórico sem operação vinculável, exibido como incompleto.
13. Usuário tentando consultar analytics de estoque alheio.
14. Período sem vendas.
15. Grande volume com paginação e plano de consulta usando índices.
16. Conferência de arredondamento: linhas e agregado fecham no centavo.
17. Tela móvel, desktop e temas claro, escuro e neon.
18. Finalização recebida por Realtime atualizando o dashboard aberto.

## 12. Ordem de implantação futura

1. Fazer backup lógico das tabelas de pedidos.
2. Aplicar `migration_order_analytics.sql` no ambiente de teste.
3. Rodar consultas de qualidade e conferir pedidos antigos.
4. Publicar o frontend com a página ainda protegida por uma constante de
   recurso, se necessário.
5. Validar manualmente um pedido conhecido contra os movimentos FIFO.
6. Liberar a navegação Análises.
7. Monitorar erros das RPCs e tempos de resposta.
8. Aplicar no ambiente principal e publicar a mesma versão validada.

A migração será aditiva. Em caso de recuo, esconder a navegação e manter as
colunas/vínculos históricos; não apagar dados analíticos já vinculados.

## 13. Fora do escopo desta primeira versão

- Lucro líquido, impostos, taxas de cartão, comissão, frete e custo fixo.
- Previsão por inteligência artificial.
- Exclusão automática de produtos.
- Produção automática de kits.
- Alteração automática de preços.
- Metas persistidas por equipe no banco.
- Comparação entre estoques de donos diferentes.

Esses recursos exigem novos dados de negócio e não devem ser simulados a
partir do CMV.

## 14. Definição de pronto

A versão estará concluída quando o usuário puder selecionar estoque, período e
kanbans; conferir receita, CMV, lucro e margem; comparar kanbans; identificar
produtos por volume, receita e contribuição; receber recomendações com motivo;
ver cobertura e sugestão de produção; e rastrear qualquer total até o pedido,
produto e lote que originou o custo. A experiência deve funcionar em celular e
computador, atualizar automaticamente e nunca apresentar custo ausente como
lucro.
