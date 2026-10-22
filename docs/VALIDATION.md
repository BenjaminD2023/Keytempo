# 功能验证与输入覆盖

记录日期：2026-10-22（Asia/Shanghai），历史验证基线 Keytempo 1.1.0 build 7，安装位置 `/Applications/Keytempo.app`。测试机为 Apple M4 MacBook Air、24 GB 内存、macOS 27.0。项目最低部署版本为 macOS 13；编译目标通过不代表已在 macOS 13 实机验证。

## 1.1.1 当前段显示与公开发布

1.1.1（build 8）恢复菜单栏显示当前输入段，约 1 Hz 更新。单位取当前输入源语言，输入源或模式变化先清除旧速率，切回也不会复活此前的 WPM／CPM；自然停打后冻结数值。中文全局输入缺少真实提交证据时显示 `— CPM`，独立 KPM 合并最近最多 128 批已接受的估算间隔，不跨上下文连接时间，不混入 confirmed 数据；距上次输入超过 30 秒后的新事件会重新预热，空闲本身不改变冻结值。应用集成自检覆盖语言往返、当前段未结束时的速度、样本不足、重复操作、全局中文 KPM／无 CPM，以及真实提交路径的 CPM。

根据用户选择，主界面的日常敲键数量只展示原“估算”一栏，保留文本上下文过滤与快捷键排除；验证输入区的 confirmed 数据和原始 CSV 不合并到日常估算中。菜单数量使用最多三位有效数字与 K／M／B 等后缀，内部汇总保持整数精度。格式自检覆盖 24 个进位、边界与大整数案例。

日常累计数量、时长与加权 KPM 合并全部已记录语言，主要 WPM／CPM 仍按当前语言。全局空格不增加数量，正常文本上下文中的空格也不主动切断连续性；下一接受间隔使用完整实际时间。近期拼音输入迹象可将候选数字、方向键与回车估算为 composition/probable，缺少迹象时仍为 unknown／navigation。该启发式没有观察真实 marked-text 或提交，不证明选词用途；真实提交字符仍仅由接入路径提供。新计数规则标识为 `adaptive-v3-no-space-ime-estimate-max…`，保留旧记录，混合规则的日均速度不强行合并。

本轮 `./scripts/test.sh` 通过：79 项测试／9 个测试集，0.591 秒；Release 构建 131.34 秒；编辑器、语言、本地化、缓冲、协调层／持久化及数量格式自检退出 0。安装版与 dist 二进制 SHA-256 一致，签名和 Info.plist 校验通过，应用内携带 MIT LICENSE。实际窗口检查确认 ABC → 系统拼音立即从 WPM 变为 CPM，合并敲键数量保持一致并使用 K/M/B 缩写；历史同时显示每日合并统计与分语言明细。未向日常数据库写入测试输入，原有数据保留。更新后全局权限需重新核验；选词用途的物理输入误计／漏计率仍未实测，不填零。

公开源代码及发布流程位于 https://github.com/BenjaminD2023/Keytempo ，采用 MIT 许可证。数据库、本地测量日志和构建产物不纳入 Git；下文 `artifacts/` 引用为历史本地记录，并不随公开仓库分发。实际输入覆盖和功耗限制继续适用，不能把隔离自检当作所有外部应用的物理输入验收。

## 证据分层

1. **统计核心测试**：直接输入已分类的元数据，验证数学、分段、汇总和容量。不能证明某应用的按键已被正确分类。
2. **适配器回调测试**：直接在 AppKit 文本控件中执行插入、标记文本和编辑回调，验证已实现的 confirmed 路径。不能替代物理键盘、第三方输入法、候选窗口和整个系统事件链路。
3. **真实应用验证**：在实际文本编辑器、浏览器输入框及聊天或代码编辑 App 中输入，与事先人工标注的用途对照。只有这一层能给出相应场景的实际误计和漏计。

这三个层级不可互相替代。纯全局监听只提供 probable；不会因为焦点角色是文本框便升级为 confirmed。

## 当前可核验的自动化范围

此前基础版本的 `./scripts/test.sh` 已完整执行成功：Swift Testing 的 **30 个测试 / 3 个测试集全部通过（当时最终复跑 0.319 秒）**，随后 Release 构建、签名校验、应用内集成自检全部退出 0。历史日志见 `artifacts/tests-release.log`。这是旧版基线，不作为 1.1.0 新语言、CPM 与迁移行为的测试结果。

基础版本另外执行了应用二进制 `--self-test-editor`：当时 14 项 AppKit 输入适配器断言、9 项实际环形缓冲断言全部通过；协调层验证了统计 → 落盘 → 重启恢复、“排除本应用也应禁止内置适配器计数”，以及“确认清除后立即退出不能复活旧数据”。这些隔离集成检查不修改用户数据库，也不向系统注入事件。

**Keytempo 1.1.0 build 5 前的单元测试基线**：Swift Testing 的 **52 个测试／6 个测试集全部通过，0.351 秒**。日志为 `artifacts/keytempo-tests-release.log`，覆盖下表的语言、单位、字符 CPM、数据库迁移和快捷键回归。Release 构建耗时 31.02 秒，`codesign --verify --strict` 与 `plutil` 校验成功；`--self-test-editor` 退出 0，输出 `PASS: editor, language, localization, buffer and coordinator/persistence integration checks`。这些结果不代表整条物理键盘、第三方输入法或外部应用链路已经通过。

此前安装为 `/Applications/Keytempo.app`，版本 **1.1.0，build 5**。已通过电脑使用工具检查实际窗口的语言切换、输入语言选择、菜单栏 KPM 选项与重启持久化，具体范围见下文。build 5 仅调整菜单弹窗的按需创建与关闭释放，Release 增量构建 16.27 秒、签名校验与全部集成自检再次通过（`artifacts/keytempo-build5.log`）；实际中英文设置及历史布局也复核通过。SQLite schema 为 `user_version=2`，当时已按用户要求清空此前历史，界面检查未写入测试输入。此后用户已产生新的日常记录；build 7 保留这些数据，不再清除。1.1.0 另做短时资源与 CPU 归属功耗复核，范围与限制见 `PERFORMANCE.md`、`POWER.md`，不替代十分钟或完整电池验收。

**build 7 新增验证范围**：完成段核心新增 `CompletedSegmentTests.swift`，覆盖确认等待不计时、当前段不提前覆盖上次结果、短段与孤立键、命令／上下文／语言／来源中断、稳定慢速回补、字符覆盖及 probable 不生成 CPM。应用内协调层新增完成结果保留与主要速度／KPM 独立选择检查；元数据自检新增 TIS 来源与 InputModeID 比较、焦点租期边界、延迟交付的有效事件、静默焦点／元数据变化及查询失败失效检查。这些自检不向系统注入键盘或输入法通知、不改用户偏好、不查询输入内容。本轮集成日志为 `artifacts/keytempo-build7-tests.log`：64 项测试／7 个测试集全部通过，0.250 秒；Release 构建 21.48 秒；应用集成自检退出 0。`codesign --verify --strict`、`plutil` 校验及安装二进制 SHA-256 对照通过。最终安装为 `/Applications/Keytempo.app`，1.1.0 build 7。

实际切换输入源时还发现了同步通知重入造成的 Swift 独占访问崩溃，因此来源状态更新先结束 `inout` 访问，再发布变化通知，并加入观察者同步回读的回归检查。修正后通过电脑使用工具实际打开设置，将系统拼音切到 ABC 并恢复系统拼音，窗口保持可用，进程未退出；另确认菜单选项仍包含独立 KPM。此前单元测试通过不能替代这一真实运行路径的复测。

build 7 菜单栏按默认最大间隔 3 秒加下一次 1 Hz 刷新确认完成，通常约 3–4 秒，定时器容差 0.2 秒且受系统调度影响；命令或上下文变化等已知中断直接结束段。等待不进入速度分母，完整统计窗口仍可展示正在输入段。菜单保留上次可用主要速度及独立 KPM，短段或缺少 CPM 覆盖的段不覆盖此前可用值；显示段的语言、证据和结束时间。缓存仅本次运行有效，重启不从每日汇总构造“上次输入段”。

测试源位于 `Tests/TypingCoreTests` 与 `Tests/TypingStoreTests`。本机 CLT 没有 XCTest，且默认 SwiftBuild 丢失 TestingMacros 的逐文件参数；脚本使用 native 构建后端并显式提供工具链中的 Testing.framework 路径。应用无 Testing 运行依赖。

| 验证目标 | 自动化覆盖位置 | 可证明的内容 |
|---|---|---|
| 0、0.2、0.4、0.6、0.8 秒五键 | `testFiveEventsHaveFourIntervalsAndNoTail` | 五键、四间隔、0.8 秒、300 KPM；等待不追加时长或改变原值 |
| 长停顿后 10、10.2、10.4 秒三键 | `testSeparateBurstsMergeWeightedIntervals` | 八键、六间隔、1.2 秒；段间停顿排除 |
| 四个 0.1 秒与四个 0.5 秒间隔 | `testWeightedSpeedIsNotAverageOfSegmentSpeeds` | 加权结果 200 KPM，不平均两个段速 |
| 单键、小样本与短消息 | `testSingleEventCountsWithoutDurationOrSpeed`、`testShortMessagesAreNotDiscarded` | 孤立键计数但不造时长；短消息的真实间隔保留 |
| 编辑与新增文字的分母 | `testEditingIncludedInProcessButBreaksNewInputRhythm` | 主要过程节奏包含编辑；新输入节奏在编辑处断开 |
| 组合操作与字符量 | `testCompositionIsOperationNotCommittedChineseCharacter` | 组合敲键不冒充最终汉字 |
| 命令、导航、未知、生成内容 | `testCommandsNavigationGeneratedAndUnknownBreakContinuity` | 不计有效分子且中断前后连接 |
| 暂停、上下文与来源变化 | `testSourceChangesAndExplicitPauseBreakContinuity`、`testEvidenceAndContextsNeverConnect` | 不把不同证据或上下文拼段 |
| 同一操作跨来源重复报告 | `testCrossSourceOperationIDsDeduplicateBeforeInterrupt` | 在提供相同操作 ID 时去重；不代表任意第三方适配器已共享 ID |
| 快节奏转稳定慢节奏 | `testAdaptiveModelRelearnsStableSlowerRhythmAndBackfills`、`testUIIdleChecksDoNotDiscardSlowerShadowCandidates` | 有界候选重估并回溯接受完整慢间隔 |
| 单独长间隔 | `testIsolatedSlowGapNeverConnectsBursts` | 不将孤立停顿按稳定慢节奏回补 |
| 跨午夜、时间调整、时区与规则变更 | `testCrossMidnightSplitsSecondsAndNumeratorWeight` 等 | 秒数及间隔权重按日拆分；时钟异常切段；旧规则保留 |
| 有界模型与去重 | `testBoundedModelDedupAndCandidatesAfterManyEvents` | 一万事件后样本与候选受限，不保留完整事件历史 |
| 完成确认与等待时间 | `CompletedSegmentTests.completionWaitsForSafeBoundAndNeverAddsConfirmationTime`、`nextBurstDoesNotReplaceCompletedRateUntilFinished` | 最后事件仍是时长终点；当前段完成前不覆盖上次结果，等待不增分母 |
| 完成边界与字符覆盖 | `CompletedSegmentTests` 其余检查、应用内协调层自检 | 命令／上下文等边界完成一次，保留慢速候选数学；短段累计不丢；主要速度与 KPM 分别保留可用结果，probable 完成不获得 CPM |
| 输入源通知重复与模式变化 | `runInputLanguageChecks` | 相同 TIS 来源通知不切段；InputModeID、实际来源或语言变化仍切段，不发送系统通知 |
| AX 有效期与异步交付 | `FocusContext.exerciseChecks` | 按捕获时间／版本验证租期，过期事件不接受；事件触发提前检查，相同控件及元数据可续期，变化或查询失败即失效 |
| 同一 W 键的上下文分类 | `MetadataClassifierTests.testSameWDependsOnContext` | 可编辑证据为 probable，非编辑或失效上下文为 unknown |
| 代码、特殊字符与修饰键 | `testTextHasNoDictionaryOrSemanticFilter` | 不通过词典或内容形态排除；全局仍只有按键规则证据 |
| 快捷键、导航、输入法选词歧义 | `MetadataClassifierTests` | Command/Control 排除；全局 Return、Tab、输入法选词键保留不确定性 |
| 常用快捷键不进入数量或分母 | `testCommonShortcutsStayExcludedAcrossContextsAndIME`、`testClassifiedShortcutBreaksTimingAndNeverIncreasesKeys` | 复制、粘贴、剪切、全选、撤销、保存、切换等 Cmd/Control 组合被排除并切段；不证明任意应用自定义快捷键均可识别 |
| 输入源语言的全部、空集与未知 | `InputLanguagePolicyTests` | 默认全部与显式空选择不同；区域／脚本变体归主要语言，`und` 可单独选择，不分析输入内容 |
| 主要单位与 WPM 数学 | `TypingRateTests` | `zh/ja/ko/th/lo/km/my` 使用 CPM；其他已知语言为估算 WPM，未知不强制选单位；200 KPM 对应 40 折算 WPM，等待不下降 |
| 批量上屏与段首字符 | `CharacterStatisticsTests.testChineseBatchUsesEntireCommitAndObservedProcessTime`、`testFirstCommitCountsButCannotInventCharacterRate` | 批量提交按全部字符计，不套字符 n−1；首事件只累计总量，无虚构速率 |
| 字符覆盖、编辑与中断 | `testEditingTimeRemainsInCharacterProcessRate`、`testUncoveredAndInvalidCountsNeverMasqueradeAsObservedZero`、`testExcludedOperationsNeverCountCharactersOrBridgeTiming` | 已覆盖的零字符编辑时间保留；缺覆盖不是零字符；命令、未知、生成操作不连接前后时长 |
| CPM 语言切换、停止及慢速回补 | `testLanguageChangeResetsSegmentAndModelEvenWhenContextIsReused`、`testCharacterRateFreezesWithoutNewEvents`、`testSlowerCandidateBackfillRatesEachCommitExactlyOnce` | 语言变化切段；停止无尾时长；候选回补不重复计提交字符 |
| 字符跨日归属 | `testCrossMidnightSplitsCharacterRateButKeepsActualCommitDay` | 速率分子与覆盖时间按跨日比例拆分；字符累计仍归真实提交日 |
| 旧数据解码与 SQLite 迁移 | `testLegacyDeltaDecodesWithUnknownLanguageAndNoCharacterCoverage`、`AggregateStoreTests.testLegacyMigrationPreservesEveryValueWithoutInventingCharacterData` | 旧记录语言 `und`，旧数量和时间保留，不补造字符覆盖或语言 |
| 迁移回滚与未来版本保护 | `testMigrationFailureRollsBackTableRebuildAndVersion`、`testFutureSchemaVersionIsRejectedWithoutOverwrite` | 失败复制可恢复原表和版本；不覆盖未知未来版本 |
| 持久化、语言分组与 CSV | `AggregateStoreTests`、`testLanguagesAndCoveredCharacterRatesRoundTripAndMerge` | 事务追加、重开恢复、证据/规则/时区/语言分列、字符覆盖往返、CSV 转义及单位、清除、磁盘错误可见 |

## 实际输入路径与待验证矩阵

**已实现的 confirmed 路径**是 App 内“验证输入”页中的原生 `NSTextView`，源码为 `Sources/Keytempo/ConfirmedEditor.swift`。适配器在一次物理键作用域内观察 `insertText`、`setMarkedText` 与 `doCommand` 等真实系统文本回调；提交字符串只在回调中计数，统计模块仅接收数量、输入源语言及覆盖元数据。已实现不等于所有输入法路径均已实测，也不能将接入能力扩展到纯全局数据。

CPM 以实际提交的扩展字素簇为数量。只有已接受且两端具备 confirmed 提交覆盖的间隔参与，使用末端提交的全部字符与完整真实时间；组合／编辑未提交时保留零字符与耗时。段首提交仅增加累计，默认至少 4 个覆盖间隔、0.5 秒并有正字符量才显示速率。异步提交已知来自手动组合、却缺少可靠间隔归属时，只计未定速率的总量并切段。全局模式缺少真实上屏数据，不能提供 CPM。

| 已标注场景 | 当前处理与证据 | 实机状态 / 误计漏计 |
|---|---|---|
| 验证区普通英文、Shift 大写 | 实际插入回调：confirmed textEntry | 回调断言及实际 App 的自动化键盘操作通过；物理键盘待验证 |
| 验证区 Option 特殊字符、死键组合 | 插入或 marked-text 回调，允许正常修饰键 | Option 插入回调回归测试已实现；真实死键组合待验证 |
| 验证区中文拼音与空格选词 | marked-text 操作属 composition；最终提交按整批字素簇计数，有覆盖间隔才生成 CPM | 人工调用组合/提交回归测试已实现；现有中文输入法真实链路待验证 |
| 验证区数字/方向键选词、回车确认、取消组合 | 依实际 marked-text 与命令回调分类；unmark 本身不推断汉字 | 候选键路径与取消组词的物理输入待验证 |
| 验证区代码、缩进、特殊字符、重复标点 | 不作语义过滤；实际换行/缩进回调属文字输入 | 实际 App 自动化换行、Tab 通过；完整代码输入/物理布局待验证 |
| 文本编辑器普通英文 | 可编辑角色与可编辑性证据 + 按键规则：probable | 日常库已有英文 probable 汇总；TextEdit 等标注实测仍待完成，暂无误计漏计率 |
| 浏览器普通页面 | 无编辑证据：unknown，不计有效速度 | 实际浏览器页面待验证 |
| 浏览器输入框与网页编辑区域 | 获得可编辑证据时 probable；拦截字母键仍可能误计 | 需分别测试标准输入框、contenteditable、拦截键页面；暂无误计率 |
| 实际聊天 App 输入框 | 支持 AX 元数据时 probable；发送回车用途不明时 unknown | 用户报告系统拼音在微信、ChatGPT 等 App 的 KPM／敲键数也易漏记；build 7 修复共用缓存与通知路径，尚未用对应 App 的物理输入确认消除漏计 |
| 游戏移动 W 与游戏聊天 | 游戏普通操作缺编辑证据时 unknown；聊天仅在 AX 可编辑证据可用时估算 | 两种上下文都待实测；无法保证所有游戏暴露正确元数据 |
| Terminal、Vim 普通/插入模式、代码编辑器 | 全局保守归 unknown 或应用排除；未接入模式用途适配器 | 不宣称支持 confirmed；插入模式也可能漏计，需专用适配器 |
| 快捷键、复制、粘贴、自动补全 | 命令/生成内容切段；验证区有相应回调拦截 | 实际 App 自动化 Cmd+V、Cmd+A 通过；补全回调断言通过；物理键盘待验证 |
| 删除、自动重复 | 删除单独计编辑；系统 repeat 标记不计独立手动敲键 | 实际 App 自动化删除计为 1 次编辑；repeat 回调断言通过；真实长按待验证 |
| 焦点快速切换、AX 超时/失效 | 版本失效后 unknown；查询在监听回调外，结果带版本；同一不透明控件及元数据可在有效期内续期 | build 7 元数据边界自检已加入；不能代替 AX 通知与快速切换的实机标注测试 |
| 权限撤销、安全输入 | 可检测时中断；不能以“无事件”断言空闲 | 系统设置需要用户授权；撤销与安全输入链路待验证 |
| 睡眠/唤醒、暂停/恢复 | 生命周期通知切段；恢复不跨中断计时 | 核心显式中断测试已有；整机睡眠/恢复待验证 |
| 全局与适配器双报 | 本 App 全局监听排除自身；核心有有界 ID 去重 | 去重数学测试已有；未来外部适配器仍须共享操作身份 |
| 中文输入源内英文直通 | 仍归中文输入源；按真实提交量参与该来源的 CPM，不按内容改成英文 | 日常库已有中文 probable 敲键汇总，但非真实字符覆盖；输入法切换／直通行为及漏计率仍待标注验证 |
| 设置的输入语言范围 | 默认全部；明确空选择停止；未知 `und` 可独立选择，全局与验证区共同遵守 | 策略／适配器自检通过；实际界面确认空选择警告、仅英文时当前中文拼音源被排除，重启保留选择。未用物理输入验证全部源 |
| 中文／English App 语言 | 界面语言与输入源语言独立，立即生效并保存 | 实际窗口立即切换，含窗口标题与原生编辑／窗口菜单；正常退出重启保留 English，最终恢复中文 |
| 历史的 WPM／CPM 分组 | 每次绘制一种来源语言，明细各语言独立；辅助 KPM 保留，缺数据不绘为零 | 语言聚合与 CSV 回归通过；实际空历史界面显示语言与独立 KPM 列。多语言有数据图表仍待实际输入验证 |

## 真实应用验证步骤

1. 使用 Release `.app`，按 README 完成输入监控与辅助功能授权，确认诊断中的权限与焦点状态。不要为测试读取输入框内容或剪贴板。
2. 在验证区、TextEdit、浏览器输入框和一个实际聊天 App 分别运行同一份人工预先标注的短操作清单：普通文字、Shift/Option、空格、换行、Tab、中文组词/选词/取消、删除、长按、快捷键、粘贴、焦点切换。内容只用于现场观察，不导入统计或诊断文件。
3. 每项记录人工操作数量及用途、预计证据等级、实际分类数量、误计数和漏计数。生成内容不进入手动字符计数；候选键不等于新增字符。
4. 记录每一段首尾事件的单调时间差；停止后等待 5 秒和 30 秒，确认已累计段内时长不变，界面明确标为最近/停止。
5. 另测游戏移动/聊天、网页拦截键、只读区域、终端和 Vim 两种模式。unknown 是保守不覆盖，不能将其记作“准确识别全部有效输入”。
6. 实测睡眠唤醒与权限撤销；保留系统状态和汇总差值，不保留按键序列。性能按 `PERFORMANCE.md` 的同条件采样流程执行。
7. 在设置切换中文／English，确认菜单、设置及统计窗口即时更新；重启后保留选择。分别测试“全部语言”、仅某一语言、显式空选择和 `und`，确认被排除语言不会增加数量或连接输入时长。
8. 按当前输入源语言检查主要单位，中文输入源英文直通仍归中文。通过内置验证区检查批量提交、零字符编辑、段首提交及异步未定速率累计；全局字符语言应显示 CPM 不可用。历史图表选单一语言，CSV 按证据／语言检查覆盖列，避免混合 WPM 和 CPM。
9. 先完成一个样本足够的英文输入段，观察约 3–4 秒后菜单显示其速度；新段进行中保留该值，完成后才替换。插入短段和全局中文无字符覆盖段，主要速度仍标记原结果的语言／时间，KPM 可独立更新。重启应显示无完成结果，不将日均当作上次输入段。
10. 在系统拼音下分别测试微信和 ChatGPT：持续字母敲键、组词选择和同一控件内停顿后续打，记录人工有效敲键与实际接受数；同时检查焦点缓存过期、重复输入源通知和真实模式切换。未知编辑证据与缺少 CPM 覆盖须分别记录，不把一种原因当成另一种原因。

误计率与漏计率目前不填零，也不从合成测试推断。完成真实标注后才能填写：误计 = 被计为有效但人工标为无效的操作；漏计 = 人工标为有效但未接受的操作。需按应用、输入源与 confirmed/probable 分开报告，并同时保留样本数量。

### 实际二进制的自动化操作样本

早期 Release 二进制曾通过电脑使用工具操作真实窗口（不是接口桩）。13 项预设有效文字/编辑操作累计为 13，其中编辑 1；这组自动化样本漏计 0。粘贴一次 10 个 ASCII 字符的测试文本，编辑器确实显示了粘贴结果，手动敲键和字符提交计数均未增加；随后 Cmd+A 替换输入一个字母，只增加 1。命令没有被误算为输入。两段自动化突发的时长约 0.3 秒，未达到展示门槛，界面正确显示“数据不足”。这是旧版操作样本，不代表 1.1.0 新增 CPM、语言范围或翻译均已完成实机验收；当前应用安装位置为 `/Applications/Keytempo.app`。

这组样本不能证明人类输入来源真实性、第三方中文输入法、TextEdit/浏览器/聊天 App 的误计漏计率。测试发现标准编辑菜单缺失导致快捷键粘贴不起作用；补上原生 responder-chain 编辑菜单后复测通过。当时的测试汇总已备份至 `artifacts/ui-smoke-test-statistics.sqlite` 并清除。build 5 又按用户明确要求清空当时历史；build 7 保留其后新增记录。schema v2 迁移兼容逻辑和隔离数据库测试仍保留，不靠推断旧记录语言生成新指标。

用户此前选择稍后自行授权；此后日常库已出现中文及英文 probable 汇总，不能继续断言全局始终未获授权。build 7 安装后实际设置窗口显示输入监控与辅助功能均未授权，点击重新检查后仍未获授权；新二进制需要用户在系统隐私设置重新允许。未操作授权开关或绕过系统。现有记录不能给出对应 App／输入法场景的完整覆盖率。三类外部 App 的人工标注、系统拼音漏计复测、睡眠／唤醒与权限撤销的整机验证仍保留为待完成项。

本轮新签名安装曾实际显示“权限不可用”和“未获得辅助功能权限”；旧版已有 probable 记录不代表新构建仍具备同样授权。最终构建须以当前系统权限及应用状态为准，必要时由用户重新允许最终安装位置，不能在权限缺失时宣称已验证全局中文链路。

### build 7 中文漏记修复的边界

已修正两个可从实现确定的中断来源：相同 TIS 输入源通知不再无条件切段，来源身份包含 InputModeID 以保留真实模式变化；排队按键先按原始时间和上下文版本检查当时有效的租期，再触发过期失效，避免清空缓存使整批原本有效的事件都失配。不支持焦点通知时，输入事件可在距到期 0.2 秒内触发提前查询，同一不透明 AX 控件身份及必要元数据才可续期。身份或元数据变化、查询失败立即使旧版本失效；过期按键不会被追认为有效，无持续高频轮询。

这些改动修复了共用元数据处理路径，不能据此宣称微信、ChatGPT 或所有系统拼音场景已实机通过。没有可靠可编辑证据的自定义输入区仍为 unknown；候选数字、空格、方向和回车仍依用途证据处理。全局监听仍无真实上屏字符，修复 KPM／敲键漏记不会自动获得 CPM。

## 界面审查

**1.1.0 实际窗口检查**：通过电脑使用工具操作已安装的应用，确认中文→English 即时翻译，包含窗口标题及原生 Edit／Window 菜单。关闭“统计所有输入语言”并明确不选任何语言时显示停止警告；仅选择英文时，当前中文拼音输入源显示已排除。选择菜单栏 KPM 选项生效。正常退出并重启后，界面与偏好中保留 `en`、`[en]`、`kpm`；检查结束恢复为中文界面、全部输入语言、主要速度模式。

build 5 实际历史窗口显示语言列与独立辅助 KPM 列；当时中文源在缺少真实提交数据时显示 CPM 不可用，没有伪造为零。当次数据库为空，因此该次界面检查不证明多语言有数据图表、实际中文提交速率、物理键盘或第三方应用输入行为。没有向日常数据库写入测试输入；此后新增日常数据由 build 7 保留。

以下为早期版本的界面基线与合成预览，保留用于说明既有检查范围，不能替代新版实际输入验收。

早期 `Views.swift` 使用当时 SDK 对 `arm64-apple-macosx13.0` 执行独立类型检查（模型及编辑器接口桩），通过。该检查验证 API 和类型兼容性，不验证真实渲染、辅助功能朗读或运行时权限。图表仅在历史标签存在时构建，视图未创建重复定时器。已确认与估算使用不同标签、颜色和数值列；清除历史使用界面内破坏性确认。

整合后还对实际 AppModel、FocusContext、InputMonitor、ConfirmedEditor、Views 与 main 全部应用源文件执行了相同 macOS 13 部署目标的 `swiftc -typecheck`，退出码 0、无编译诊断。

另已在独立、隐藏的 AppKit 窗口中渲染菜单、今日概况、历史、设置与诊断页并人工检查 PNG。输出位于 `docs/ui-preview/`，**全部数字、状态、权限标记与诊断 p99 均为合成的界面测试夹具**，不是实际输入记录或性能结果。此检查未启动系统监听、未访问用户数据库、未抓取屏幕，也未操作正在运行的 App。历史标签仅在临时副本中改变初始选项，其他视图布局使用实际源文件。检查发现并修正了排除名单录入布局，增加原生应用选择器，并明确区分包含组合/编辑的过程节奏与只连接 textEntry 的文字敲键节奏。
