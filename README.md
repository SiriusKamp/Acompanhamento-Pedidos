# Acompanhamento de Pedidos — Front

Frontend React + Vite para criar pedidos, acompanhar o preparo e consultar produtos importados. Não há backend neste repositório.

## Executar

Requer Node.js 20 ou superior.

```bash
npm install
npm run dev
```

Abra `http://localhost:5173`. O Vite encaminha chamadas `/api` para a API de pedidos em `http://localhost:8086`, sem exigir CORS durante o desenvolvimento local. O front inicia no modo API; enquanto o backend não estiver pronto, clique em **Ativar demonstração** para usar dados locais e **Importar produtos** para inserir os exemplos. Os dados de demonstração ficam no `localStorage` deste navegador e não são enviados à API.

Na aba Pedidos, **Criar pedido** abre um modal com busca, botões de quantidade, valor sugerido, valor final editável, valor pago e troco ou valor pendente. Os pedidos podem passar por aguardando, preparando, finalizados e cancelados. Na aba Produtos é possível consultar os importados e editar seu preço de venda. Alterar um preço não modifica pedidos já criados.

## Integração com a API de pedidos

O front chama **apenas a API de pedidos**. O fluxo de importação solicita a conexão com uma conta do Estoque através dessa API; cabe ao backend de pedidos acessar a API Estoque. A senha digitada não é salva no navegador. Veja os endpoints e os JSONs completos em [API_CONTRACT.md](API_CONTRACT.md).

Para desenvolvimento local, mantenha `VITE_PEDIDOS_API_URL` ausente e rode a API em `http://localhost:8086`. Para um front publicado em outro domínio, configure `VITE_PEDIDOS_API_URL` com a origem pública da API e libere a origem do front no CORS do backend. Nunca coloque senhas ou chaves privadas em variáveis `VITE_`.

```bash
npm run build
npm run preview
```

Esta primeira versão não implementa login próprio do serviço de pedidos, atualização em tempo real nem processamento de pagamentos: o valor pago é registrado para cálculo e exibição. A API deve persistir produtos e pedidos.
