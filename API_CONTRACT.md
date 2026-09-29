# Contrato HTTP esperado pelo frontend

Base local: `http://localhost:8086/api/v1`. Durante `npm run dev`, o front usa `/api/v1` e o Vite encaminha para a porta 8086. JSON usa `Content-Type: application/json`; valores monetários são números em reais (por exemplo, `59.99`), nunca strings formatadas. Datas são ISO 8601. IDs são strings (preferencialmente UUID). Em erro, retorne um status HTTP apropriado e `{"detail":"Mensagem legível"}`.

O front chama apenas a API **acompanhamento-de-pedidos**. A API de pedidos faz a comunicação com a API Estoque. A conexão temporária do Estoque representa o usuário de estoque escolhido, independentemente de um futuro login próprio no serviço de pedidos.

Depois de `POST /stock/connections`, o front envia `X-Orders-Session: <connectionId>` nas demais chamadas. O identificador fica em `sessionStorage`; o token real do Estoque fica somente na memória do backend de pedidos. Sem sessão, `GET /products` e `GET /orders` devolvem `[]` para permitir a primeira importação. A sessão expira e precisa ser refeita após reiniciar o backend.

## Catálogo importado

### `GET /products`

Retorno `200`: array completo dos produtos importados para pedidos.

```json
[
  {
    "id": "b4523cdf-53e1-4de7-b78a-43d627d6ee0d",
    "sourceProductId": "b32d57f5-2940-4f4a-9859-4ec45636ab4d",
    "sourceStockId": "e32bc6b2-874e-4564-a689-5f7c2d102a98",
    "name": "Coca-Cola 2 L",
    "code": "BEB-001",
    "category": "Bebidas",
    "isKit": false,
    "suggestedPrice": 12.9,
    "price": 13.5,
    "importedAt": "2026-09-28T14:10:00Z"
  }
]
```

`suggestedPrice` pode ser `null`. `price` é o preço escolhido pelo usuário na importação, ou o sugerido quando não foi alterado.

### `PATCH /products/{id}`

Corpo: `{"price": 14.5}`. Retorno `200`: objeto de produto completo no mesmo formato acima, com `price` atualizado. Pedidos anteriores mantêm seu preço unitário registrado.

## Importação do Estoque

### `POST /stock/connections`

Corpo:

```json
{"email":"estoque@exemplo.com","password":"senha-da-conta-de-estoque"}
```

Retorno `200`:

```json
{
  "connectionId": "7a49fdd9-97d6-4cbf-922b-8de0dd11f98c",
  "stocks": [
    {"id":"e32bc6b2-874e-4564-a689-5f7c2d102a98","name":"Estoque Principal"}
  ]
}
```

O backend autentica na API Estoque, devolve somente um identificador opaco e mantém a sessão por tempo limitado. Não devolva o token do Estoque ao navegador. `stocks` contém apenas os estoques acessíveis por essa conta. O front descarta a senha após a conexão.

### `GET /stock/connections/{connectionId}/stocks/{stockId}/products?page=0&size=100`

Retorno `200`, paginado, apenas produtos e kits ativos do estoque selecionado:

```json
{
  "rows": [
    {
      "sourceProductId": "b32d57f5-2940-4f4a-9859-4ec45636ab4d",
      "name": "Coca-Cola 2 L",
      "code": "BEB-001",
      "category": "Bebidas",
      "isKit": false,
      "suggestedPrice": 12.9
    }
  ],
  "total": 1,
  "page": 0,
  "size": 100
}
```

`page` começa em 0. `suggestedPrice` pode ser `null` se o Estoque não tiver preço sugerido. Para kits, use `suggested_sale_price`; para produtos comuns, use `suggested_sale_price` ou `next_sale` do catálogo da API Estoque. A validação de posse do estoque ocorre no backend.
Consultar este endpoint também escolhe `stockId` como estoque ativo da sessão. Assim `GET /products` e `GET /orders` voltam a mostrar dados persistidos após uma reconexão, mesmo sem nova importação.

### `POST /products/import`

Corpo:

```json
{
  "connectionId": "7a49fdd9-97d6-4cbf-922b-8de0dd11f98c",
  "stockId": "e32bc6b2-874e-4564-a689-5f7c2d102a98",
  "items": [
    {"sourceProductId":"b32d57f5-2940-4f4a-9859-4ec45636ab4d","price":13.5}
  ]
}
```

Retorno `200`: array dos produtos importados no formato de `GET /products`. A importação deve ser idempotente por `(sourceStockId, sourceProductId)`: se o produto já existir, atualize seus dados/preço em vez de duplicá-lo. O backend deve validar `connectionId`, `stockId`, IDs de produto e preços não negativos.

## Pedidos

### `GET /orders`

Retorno `200`: array de pedidos, preferencialmente do mais recente para o mais antigo.

```json
[
  {
    "id": "32f26d9b-806a-4274-9656-273defe24233",
    "number": 42,
    "customer": "Mesa 04",
    "note": "Sem gelo",
    "items": [
      {"productId":"b4523cdf-53e1-4de7-b78a-43d627d6ee0d","name":"Coca-Cola 2 L","quantity":2,"unitPrice":13.5}
    ],
    "suggestedTotal": 27.0,
    "finalTotal": 25.0,
    "paid": 30.0,
    "status": "waiting",
    "createdAt": "2026-09-28T14:20:00Z",
    "updatedAt": "2026-09-28T14:20:00Z"
  }
]
```

Status permitidos: `waiting` (aguardando), `preparing`, `finished`, `cancelled`. O front calcula o troco como `max(0, paid - finalTotal)` e o pendente como `max(0, finalTotal - paid)`. O backend deve devolver `unitPrice` como fotografia do preço na criação; importações e mudanças de preço posteriores não alteram o pedido.

### `POST /orders`

Corpo:

```json
{
  "customer": "Mesa 04",
  "note": "Sem gelo",
  "items": [{"productId":"b4523cdf-53e1-4de7-b78a-43d627d6ee0d","quantity":2}],
  "finalTotal": 25.0,
  "paid": 30.0
}
```

Retorno `201` ou `200`: objeto completo no formato de `GET /orders`, com status inicial `waiting`. `customer` e `note` podem ser strings vazias. Quantidade é inteiro positivo. O backend calcula `suggestedTotal` e os preços unitários a partir do catálogo; `finalTotal` é a substituição que o usuário definiu no modal.

### `PATCH /orders/{id}/status`

Corpo: `{"status":"preparing"}`. Retorno `200`: pedido completo atualizado. Transições exibidas pelo front: `waiting` → `preparing` ou `cancelled`; `preparing` → `finished` ou `cancelled`; `cancelled` → `waiting`. `finished` não tem ação adicional nesta versão.

## Desenvolvimento e implantação

Ainda não existe autenticação própria da API de pedidos no front. Quando isso for adicionado, preserve a separação entre a identidade do serviço de pedidos e a conta escolhida para acessar o Estoque. O front mantém `connectionId` em `sessionStorage` até fechar a aba; uma sessão expirada exige nova conexão com o Estoque.

Em desenvolvimento, `vite.config.ts` faz proxy para `http://localhost:8086`; a API não precisa liberar CORS para `localhost:5173`. Em produção, configure `VITE_PEDIDOS_API_URL` com a origem pública da API, e a API deve liberar via CORS a origem publicada do front. Essa variável é pública e não deve conter chaves.
