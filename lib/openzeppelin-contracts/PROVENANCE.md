# Vendored math dependency

Only `contracts/utils/math/Math.sol` and the upstream MIT `LICENSE` are vendored from OpenZeppelin Contracts tag **v5.0.2**. No package manager, git checkout, or submodule is needed.

- Source: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/utils/math/Math.sol
- License: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/LICENSE
- Downloaded source SHA-256: `a6ee779fc42e6bf01b5e6a963065706e882b016affbedfd8be19a71ea48e6e15`
- License SHA-256: `0e05b4f45c8769ece14ba2d202bf6f5ed7132600b642c981266f7255e0187ea3`

The dependency is unchanged. Only `min` and the two `mulDiv` overloads are used by the production contract. The MIT copyright notice and original algorithm attribution remain in the vendored files.
