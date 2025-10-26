// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBankV2
 * @notice Bóveda multi-token con control de acceso, oráculo Chainlink y contabilidad en USD (Sepolia)
 * @author EALucero
 */
contract KipuBankV2 is AccessControl {
    // ─────── ROLES ─────── //
    /// @notice Rol administrativo con permisos para configurar tokens y parámetros
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ─────── CONSTANTES ─────── //
    /// @notice Dirección que representa ETH como token nativo
    address public constant NATIVE_TOKEN = address(0);
    /// @notice Dirección del oráculo Chainlink ETH/USD en Sepolia
    address public constant FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    /// @notice Dirección del contrato USDC en Sepolia
    address public constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    /// @notice Cantidad de decimales que maneja USDC
    uint8 public constant USDC_DECIMALS = 6;
    /// @notice Constante para almacenar el latido (heartbeat) del Data Feed
    uint16 public constant ORACLE_HEARTBEAT = 3600; // 1 hora
    /// @notice Constante para almacenar el factor de decimales
    uint256 public constant DECIMAL_FACTOR = 1e20;

    // ─────── VARIABLES IMMUTABLES ─────── //
    /// @notice Límite global de depósitos en el banco en USDC
    uint256 public immutable bankCapUSD;
    /// @notice Umbral máximo de retiro por transacción en USDC
    uint256 public immutable withdrawalLimitUSD;

    // ─────── VARIABLES DE ESTADO ─────── //
    /// @notice Variable para almacenar la dirección del Chainlink Feed
    AggregatorV3Interface public immutable ethUsdPriceFeed; // 0x694AA1769357215DE4FAC081bf1f309aDC325306 Ethereum ETH/USD
    /// @notice Mapeo de bóvedas por usuario y token
    mapping(address => mapping(address => uint256)) public vaults; // vaults[user][token]
    /// @notice Mapeo de decimales por token
    mapping(address => uint256) public tokenDecimals; // token => decimals
    // @notice Total de depósitos realizados
    uint256 public totalDeposits;
    /// @notice Total de retiros realizados
    uint256 public totalWithdrawals;
    /// @notice Centinela para prevenir reentrancia
    bool private locked;

    // ─────── EVENTOS ─────── //
    /// @notice Emitido cuando un usuario deposita fondos
    event Deposit(address indexed user, address indexed token, uint256 amount);
    /// @notice Emitido cuando un usuario retira fondos
    event Withdrawal(address indexed user, address indexed token, uint256 amount);

    // ─────── ERRORES ─────── //
    /// @notice El token proporcionado no está registrado o no tiene decimales configurados
    error InvalidToken();
    /// @notice El depósito excede el límite global permitido por el banco
    error CapExceeded();
    /// @notice El usuario intenta retirar más fondos de los que tiene en su bóveda
    error InsufficientBalance();
    /// @notice Falló la transferencia de fondos (ETH o ERC-20)
    error TransferFailed();
    /// @notice El monto ingresado es cero, o sea nulo
    error ZeroAmount();
    // @notice El retiro solicitado supera el límite máximo permitido por transacción
    error WithdrawalLimitExceeded();
    /// @notice El contrato no tiene suficiente allowance aprobado por el usuario para transferir tokens
    error InsufficientAllowance();
    /// @notice El dato del oráculo está desactualizado o es inválido según el heartbeat configurado
    error StaleOracleData();

    // ─────── MODIFICADORES ─────── //
    /// @notice Guardia que previene reentrancia en funciones críticas
    modifier nonReentrant() {
        require(!locked, "ReentrancyGuard: reentrant call");
        locked = true;
        _;
        locked = false;
    }

    // ─────── CONSTRUCTOR ─────── //
    /**
     * @notice Inicializa el contrato con límites y roles
     * @param _bankCapUSD Límite total de depósitos en USD
     * @param _withdrawalLimitUSD Límite máximo de retiro por transacción en USD
     */
    constructor(uint256 _bankCapUSD, uint256 _withdrawalLimitUSD) {
        if (_bankCapUSD == 0 || _withdrawalLimitUSD == 0 || _withdrawalLimitUSD > _bankCapUSD) revert CapExceeded();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        bankCapUSD = _bankCapUSD;
        withdrawalLimitUSD = _withdrawalLimitUSD;
        ethUsdPriceFeed = AggregatorV3Interface(FEED);

        tokenDecimals[NATIVE_TOKEN] = 18;
        tokenDecimals[USDC] = 6;
    }

    // ─────── FUNCIONES DE DEPÓSITO ─────── //
    /// @notice Permite depositar ETH directamente
    receive() external payable {
        if (msg.value == 0) revert ZeroAmount();
        _deposit(NATIVE_TOKEN, msg.value);
    }

    /**
     * @notice Deposita ETH o tokens ERC-20 en la bóveda
     * @param token Dirección del token a depositar (ETH usa address(0))
     * @param amount Monto a depositar
     */
    function deposit(address token, uint256 amount) external payable {
        if (amount == 0) revert ZeroAmount();
        if (token == NATIVE_TOKEN) {
            require(msg.value == amount, "ETH mismatch");
        } else {
            uint256 allowance = IERC20(token).allowance(msg.sender, address(this));
            if (allowance < amount) revert InsufficientAllowance();
            IERC20(token).transferFrom(msg.sender, address(this), amount);
        }
        _deposit(token, amount);
    }

    /**
     * @notice Lógica interna para registrar depósitos
     * @param token Dirección del token depositado
     * @param amount Monto depositado
     */
    function _deposit(address token, uint256 amount) internal {
        uint256 usdValue = _convertToUSD(token, amount);
        if (totalDeposits + usdValue > bankCapUSD) revert CapExceeded();

        vaults[msg.sender][token] += amount;
        totalDeposits += usdValue;

        emit Deposit(msg.sender, token, amount);
    }

    // ─────── FUNCIONES DE RETIRO ─────── //
    /**
     * @notice Retira fondos de la bóveda personal
     * @param token Dirección del token a retirar
     * @param amount Monto a retirar
     */
    function withdraw(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (vaults[msg.sender][token] < amount) revert InsufficientBalance();

        uint256 usdValue = _convertToUSD(token, amount);
        if (usdValue > withdrawalLimitUSD) revert WithdrawalLimitExceeded();

        vaults[msg.sender][token] -= amount;
        totalWithdrawals += usdValue;

        if (token == NATIVE_TOKEN) {
            (bool success, ) = msg.sender.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(token).transfer(msg.sender, amount);
        }

        emit Withdrawal(msg.sender, token, amount);
    }

    // ─────── FUNCIONES DE CONSULTA ─────── //
    /**
     * @notice Consulta el balance de la bóveda de un usuario para un token específico
     * @param user Dirección del usuario
     * @param token Dirección del token
     * @return balance Monto depositado en la bóveda
     */
    function getVaultBalance(address user, address token) external view returns (uint256) {
        return vaults[user][token];
    }

    /**
     * @notice Retorna estadísticas globales del contrato
     * @return deposits Total de depósitos en USD
     * @return withdrawals Total de retiros en USD
     */
    function getStats() external view returns (uint256 deposits, uint256 withdrawals) {
        return (totalDeposits, totalWithdrawals);
    }

    /**
     * @notice Consulta el balance total en USD de un usuario considerando múltiples tokens
     * @param user Dirección del usuario
     * @param tokens Lista de tokens a consultar
     * @return totalUSD Suma total en USD
     */
    function getTotalBalanceUSD(address user, address[] calldata tokens) external view returns (uint256 totalUSD) {
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 amount = vaults[user][tokens[i]];
            totalUSD += _convertToUSD(tokens[i], amount);
        }
    }

    // ─────── FUNCIONES ADMINISTRATIVAS ─────── //
    /**
     * @notice Configura los decimales de un token
     * @param token Dirección del token
     * @param decimals Cantidad de decimales
     */
    function setTokenDecimals(address token, uint8 decimals) external onlyRole(ADMIN_ROLE) {
        tokenDecimals[token] = decimals;
    }

    // ─────── FUNCIONES INTERNAS ─────── //
    /**
     * @notice Convierte un monto de token a su equivalente en USD
     * @dev Si el token es ETH, usa el oráculo Chainlink ETH/USD. Si es USDC, se asume paridad 1:1.
     * @param token Dirección del token a convertir
     * @param amount Monto del token a convertir
     * @return usdValue Valor estimado en USD con base en los decimales configurados
    */
    function _convertToUSD(address token, uint256 amount) internal view returns (uint256) {
        uint256 rawDecimals = tokenDecimals[token];
        if (rawDecimals == 0 || rawDecimals > 255) revert InvalidToken();
        uint8 decimals = uint8(rawDecimals);

        uint256 normalized = amount / (10 ** (decimals - USDC_DECIMALS));

        if (token == NATIVE_TOKEN) {
            (uint80 roundID, int256 price, , uint256 updatedAt, uint80 answeredInRound) = ethUsdPriceFeed.latestRoundData();
            if (answeredInRound < roundID || block.timestamp - updatedAt > ORACLE_HEARTBEAT) revert StaleOracleData();
            return (normalized * uint256(price) * DECIMAL_FACTOR) / (10 ** 8 * DECIMAL_FACTOR);
        }

        if (token == USDC) {
            return normalized;
        }

        return normalized;
    }

    /**
     * @notice Convierte un monto en USD a su equivalente en ETH
     * @dev Usa el oráculo Chainlink ETH/USD para calcular el valor en wei
     * @param usdAmount Monto en USD a convertir
     * @return ethAmount Monto equivalente en ETH (en wei)
     */
    function convertUSDToETH(uint256 usdAmount) external view returns (uint256) {
        (, int256 price,,,) = ethUsdPriceFeed.latestRoundData();
        return (usdAmount * 10 ** 8 * (10 ** (18 - USDC_DECIMALS))) / uint256(price);
    }
}