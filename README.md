# KipuBankV2

KipuBankV2 es un contrato inteligente que permite a los usuarios depositar y retirar ETH o tokens ERC-20 (como USDC) en bóvedas personales, con contabilidad en USD, límites configurables y seguridad reforzada.

## 📋 Características

- 💸 Depósitos en ETH o tokens ERC-20 (USDC por defecto)
- 🔐 Retiros limitados por transacción (withdrawalLimitUSD)
- 🏦 Límite global de depósitos (bankCapUSD)
- ✍🏼 Contabilidad en USD usando Chainlink ETH/USD
- 🧮 Conversión USD ↔ ETH con precisión decimal
- 🛡️ Protección contra reentrancia
- ⛔ Bloqueo de depósitos sin valor (amount == 0)
- 📊 Estadísticas globales (getStats)
- 🧾 Bóvedas personales por token (vaults[user][token])
- 🧠 Validación de frescura del oráculo (ORACLE_HEARTBEAT)
- 🧩 Decimales configurables por token (setTokenDecimals)
- 📣 Eventos en depósitos y retiro

## 🛠️ Despliegue

1. Clona el repositorio:
    - git clone https://github.com/EALucero/KipuBankV2.git
    - cd KipuBankV2
2. Deployar en Remix usando la red Sepolia.
3. Al momento del despliegue, configurar:
    - bankCapUSD: límite global de depósitos (ej. 1e19 para 10 ETH en USD).
    - withdrawalLimitUSD: límite por retiro (ej. 1e18 para 1 ETH en USD).

## ☝🏼 Como interactuar

- Usá deposit(token, amount) para depositar ETH (address(0)) o USDC.
- Usá withdraw(token, amount) para retirar dentro del límite permitido.
- Consultá tu bóveda con getVaultBalance(user, token).
- Obtené tu balance total en USD con getTotalBalanceUSD(user, tokens[]).
- Consultá estadísticas globales con getStats().

## 🔍 Variables clave
- vaults[user][token]: Monto depositado por usuario y token
- totalDeposits: Total acumulado de depósitos en USD
- totalWithdrawals: Total acumulado de retiros en USD
- bankCapUSD: Límite global de depósitos
- withdrawalLimitUSD: Límite máximo por retiro
- tokenDecimals[token]: Decimales configurados por token
- ethUsdPriceFeed: Oráculo Chainlink ETH/USD (Sepolia)
- USDC: Dirección del contrato USDC en Sepolia
- FEED: Dirección del oráculo Chainlink ETH/USD
- ORACLE_HEARTBEAT: Latido máximo del oráculo (3600 segundos)
- DECIMAL_FACTOR: Factor de precisión para cálculos con decimales

## ✅ Verificación de contrato
https://sepolia.etherscan.io/address/0x99fbd0638a8c8a07cc511f52ca2cd74dd03549e4