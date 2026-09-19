# 验证记录 / Validation

本次记录于 2026-09-19，从公开仓库的导出目录重新编译和执行。完整测试名称与状态见 [test-results.json](test-results.json)。

## 本地测试

环境：Foundry `1.7.1`，Solidity `0.8.26`，EVM `cancun`，优化器开启、`runs = 1`、`via_ir = true`。不需要私钥、主网余额或默认 RPC。

**42 项通过、0 项失败、1 项跳过。** 通过项包括 3 个模糊测试，每个 256 次，共 768 次输入执行；这些执行次数不是另外 768 个独立测试用例。

| 测试合约 | 通过 | 范围 |
| --- | ---: | --- |
| `BasketIndexTest` | 9 | 权重与精度、延迟更换、访问控制、失效恢复 |
| `V2IndexSourceTest` | 7 | 均价预热、短时现货变动、过期、流动性、累计值与时间溢出 |
| `DidxBasketTest` | 8 | 一次初始化、净到账、赎回下限、捐赠、损失、冻结回滚、往返不增益 |
| `DidxFiveChooseFourTest` | 8 | 独立组合、登记限制、跨组合隔离、回购路径及继承的主池测试 |
| `DidxLaunchTest` | 2 | dIDX 主池创建、买卖、实物赎回、拒绝混合池 |
| `DidxRefundGatewayTest` | 8 | 原币和 BNB 退款、历史残留隔离、退款失败回滚、转账税、可选 Meme 买入 |
| `BasketSourcesForkTest` | 0 | 1 项跳过：未设置 `FORK_TESTS`，未执行历史分叉检查 |

复现：

```bash
git clone --recurse-submodules https://github.com/kontulbunder-oss/BEP-888.git
cd BEP-888
forge test -vv
python scripts/verify-source.py
```

Python 校验脚本使用 Python 3.9+ 标准库，无第三方依赖。Windows 用户应克隆到较短路径，例如 `C:\src\BEP-888`；第三方依赖的嵌套子模块很深，长工作区路径可能触发 Git 的 `$GIT_DIR too big`。本次 Windows 环境中两项未用到的第三方嵌套测试子模块遇到该路径限制；本仓库所需依赖已就绪，以上 42 项测试实际通过。

### 可选历史分叉

默认跳过的测试使用 BSC 区块 `122592000`；需要能访问历史状态的 RPC。这项测试验证历史池的价格路径，不代表测试时刻的主网退出保证。

```bash
BSC_RPC_URL=https://YOUR_ARCHIVE_BSC_RPC FORK_TESTS=true forge test --match-contract BasketSourcesForkTest -vv
```

PowerShell：

```powershell
$env:BSC_RPC_URL = 'https://YOUR_ARCHIVE_BSC_RPC'
$env:FORK_TESTS = 'true'
forge test --match-contract BasketSourcesForkTest -vv
Remove-Item Env:FORK_TESTS
Remove-Item Env:BSC_RPC_URL
```

这两个示例只发起只读 RPC，Foundry 在本地执行分叉调用，不向主网广播交易。

## 源码与依赖

[source-manifest.json](../deployments/source-manifest.json)记录 29 个 Solidity 源码与测试文件的 SHA-256。本次导出逐个与原项目文件比较，字节完全相同。`.gitattributes` 对 Solidity 禁用换行转换，避免 Windows 提交改变哈希。

Git 子模块锁定的主要依赖：

| 依赖 | 提交 |
| --- | --- |
| PancakeSwap infinity-periphery | `4efea658a051305052a948c74632c01470e769e2` |
| infinity-core | `891259f3b0ba32a8c9f91f903ed4e8ae2bbda3ff` |
| core/OpenZeppelin | `659f3063f82422cef820de746444e6f6cba6ca7c` |
| core/forge-std | `726a6ee5fc8427a0013d6f624e486c9130c0e336` |

这些校验用于源码来源与可复现性，不等于独立安全审计。

## 主网只读核对

[bsc-mainnet.json](../deployments/bsc-mainnet.json)记录 BSC 区块 **122770823** 的区块哈希、时间、12 个合约地址、代码哈希、储备、平台候选、发射费与绑定检查。

- dIDX 的四项资产与网站默认组合一致，已初始化且四项储备非零。
- NAV、购买/赎回 Gateway 和退款 Gateway 均绑定同一 dIDX；退款入口引用正确购买 Gateway 和 Meme 路由。
- Registry、发射台和默认组合 mask `15` 的关联一致。
- 普通 Meme 创建费为 `0.005 BNB`，与 dIDX 铸造不同。
- 本次读取时第五候选未绑定；不将测试用 MDAQ 当作生产平台币。
- 网站参考指数地址已部署。发射台的 `indexOracle()` 本次返回零地址：首页参考指数不是发射台已绑定的默认指数，不能混淆二者。
- 12 个合约的编译运行时代码在移除 CBOR 元数据、屏蔽 immutable 插槽后均与链上代码一致。主要 dIDX 与集成模块使用优化器 `runs = 1`；先前独立部署的参考指数使用 `runs = 200`。每项设置记录在清单中。

编译参考指数的对应设置：

```bash
forge build src/index/MemeBasketIndex.sol --optimizer-runs 200 --out out-reference-index --cache-path cache-reference-index
```

**比较范围：**规范化后的运行时代码一致不等于完整部署字节、所有构造参数或存储状态逐字节一致。清单中列出的绑定另行通过 `eth_call` 检查。读取没有验证全部外部代币权限、实时价格新鲜度或未来交易成功率。

可以使用 Foundry `cast` 自行核对核心地址，例如：

```bash
cast call 0x5C36146A69abFd68346d801AfB911B97C18eb4b5 "assets()(address[4])" --rpc-url "$BSC_RPC_URL"
cast call 0xc1359a0eDbdB727cd2686498be7A7403959C7C27 "basket()(address)" --rpc-url "$BSC_RPC_URL"
cast call 0xc1359a0eDbdB727cd2686498be7A7403959C7C27 "purchaseGateway()(address)" --rpc-url "$BSC_RPC_URL"
```

清单是指定区块的快照，储备、owner 和配置可能随后变化。网站实际报价应读取当前区块并模拟用户本次操作。
