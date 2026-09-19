# 权限与模块边界 / Authority boundaries

以下说明对应本仓库源码。链上地址与本次只读核对结果见 [部署清单](../deployments/bsc-mainnet.json)。权限说明不能由“去中心化”“指数”或代币名称推断，必须逐个合约检查。

| 模块 | 谁可以操作 | 可以做什么 | 不能由此推断的权限 |
| --- | --- | --- | --- |
| `DidxBasket` | 构造时固定的 initializer 一次初始化；此后用户存入、持有者赎回 | 按实际净到账发行、销毁自己份额取回比例储备 | 没有 owner 提款、升级、改成分、再平衡；initializer 不是持续管理员 |
| `DidxGateway` | 用户 | 沿固定路径购买、铸造或赎回换 BNB | 没有改路由、改篮子或管理员提款入口 |
| `DidxRefundGateway` | 用户 | 购买、精确存入、原币退款、可选买 Meme | 不能调用后修改 basket / purchaseGateway / memeRouter；历史余额不归本次付款人 |
| `DidxNavFeed` | 任何人可维护价格观察 | 调用固定来源更新、读取储备净值 | 不能自由设价格、转走储备或替换来源 |
| `DidxBasketRegistry` | 当前 launchpad owner | 一次绑定平台币候选；登记符合代码、成分、初始化与储备检查的篮子 | 不能改既有篮子的成分或将旧份额变成新组合；同一组合不能重复登记 |
| `MemeDaqLaunchpad` | owner；部分操作允许 priceKeeper | 设置报价源、发射费、起始参数、登记/启停参考指数、池买入暂停和流出限制等 | 不赋予提取 dIDX 核心储备的能力 |
| `MemeBasketIndex` | owner 提案；延迟后任何人可按已提交参数执行 | 初始设置参考成分；一天延迟后替换参考成分；受约束的失效恢复 | 参考指数的替换不会替换 dIDX 实际储备；执行者不能随意给一个指数值 |
| `MdaqBuyback` | owner 设置平台币、keeper、价格与路径相关配置；keeper 执行受约束回购 | 管理回购配置和执行 | 不赋予取走用户 dIDX 或核心篮子储备的能力 |

发射台 owner 可以暂停或恢复指定计价资产的池买入；priceKeeper 只能触发暂停，不能恢复。持有者直接向 `DidxBasket` 赎回实物没有读取发射台暂停状态。退出仍取决于底层资产是否能转账，换 BNB 另取决于各条交易路径。

`Ownable2Step` 模块的所有权变更需要候选新 owner 接受。应核对各模块实际 `owner()`，不能把一个地址自动视为全部模块 owner。

## MDAQ 金库与 dIDX 核心不同

平台税费金库的自动执行和升级属于独立模块，本仓库没有导出其运维账户、签名材料或自动执行器。金库若持有 dIDX，可按它持有的份额赎回；这不构成取走其他持有者储备的权限。不能把平台金库的升级能力描述成 `DidxBasket` 可升级。

## Integrator checklist

- Resolve the exact basket address for the selected composition; read that contract's assets and the connected gateway.
- Read balances and allowances for that same share address. Similar names or symbols are insufficient.
- Keep in-kind redemption and BNB conversion as separate choices; show approval separately from execution.
- Measure actual token receipts and use explicit output limits and deadlines. Never remove limits merely to hide a reverted quote.
- A website valuation, an oracle update, and a transaction confirmation are different events. Display their timestamps and stages separately.

The reserve share contract has no upgrade administrator. Adjacent registries, the launchpad, index management, and buyback infrastructure retain their own explicit permissions.
