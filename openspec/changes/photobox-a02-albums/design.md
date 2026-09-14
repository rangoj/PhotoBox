## Context

See proposal.md for scope and the exact Stitch reference. 用户已确认不保留搜索和用户图标。当前 `AlbumsWorkspaceView` 为队列列表；`PhotoAlbumDescriptor` 只有 id/title/count，`PhotoLibraryReading` 缺少集合读取，`PhotoLibraryMutating` 已有创建空相册能力。`AlbumSelectionFlow.createAndArchive` 会立刻归档当前照片，不能直接用作首页新建相册。

`AppModel` 组合照片服务、任务存储、缩略图和模拟/真实 mutation backend。A01 已建立「整理 / 相册 / 我的」三个 Tab。现有 `DecisionQueueModel` 管理稍后决定和已保护，应保留其持久化与恢复语义。

## Goals / Non-Goals

**Goals:** 真实集合目录、稳定封面与数量、新建空相册、基本只读浏览、明确失败恢复；保持现有 A01 和归档流程兼容。

**Non-Goals:** 完整 A04 选择/移出/批量加入/整理入口、A05 大图与播放功能、队列页面重做、账号、搜索、会员、云同步、Face ID 或新的照片决定语义。

## Decisions

1. **只读目录放在照片读取边界。** 在 `PhotoLibraryReading` 增加可抛错的集合目录与单集合成员读取 API，并使用包含 id、kind、title、accessibleCount、coverAssetID 的轻量值类型。Live 实现读取 regular albums 和 favorites smart album；首页只读取数量及单张封面，进入内容页后才枚举该集合成员。相比从 mutator 枚举再逐相册与全库求交，这避免把读取绑定到 DEBUG 模拟写入模式，并减少重复全库扫描。现有测试替身获得明确空目录默认实现，新相册测试提供真实 fixture 实现。

2. **首页投影与加载状态独立。** 新增轻量 `AlbumHomeModel`，由 `AppModel` 注入 reader、mutator、最近相册 IDs 和已有 thumbnail loader。投影负责快速访问去重、最多三个常用相册和稳定排序；异步读取使用请求代次，防止过期响应覆盖最新授权范围。进入相册 Tab、前台恢复、显式刷新和新建成功时更新目录。只发生收藏、相册改名或成员变动时也需要刷新；不能只依赖 asset added/removed 差异。

3. **原始画板结构映射到真实能力。** 保留深灰黑背景、浅色名称、蓝色加号、横向小封面和两列方形封面；顶部只有相册和加号。快速访问以收藏和现有 recentAlbumIDs 为基础，不建立新的置顶存储。我的相册包括空相册。画板的 Pro、同步优化、Face ID、版本与 RAW 示例标签不映射成未经支持的功能状态。所有数量与名称来自数据源。

4. **新建与归档分离。** 用现有 `PhotoLibraryMutating.createAlbum` 提交用户明确的新建空相册命令。界面状态包括输入、提交中、成功、失败；trim 空名称，提交中禁用重复点击并阻止误关闭。返回成功 ID 后更新目录；nil 结果提示刷新确认，绝不自动重放。保留输入以便用户处理确定的失败。成功返回后若目录刷新失败，保留已创建对象并只重试读取。无自动重启重放，因此不增加持久化事务或使用伪照片 ID。

5. **模拟与真实读取保持可辨。** 正常目录总是读取当前授权照片库。DEBUG 模拟新建时，仅把模拟对象加入当前模拟会话并显示明确模拟反馈，不声称系统相册已创建；关闭模拟模式后移除该会话对象。UI 测试注入一致的目录 reader 和模拟 mutator，确定性验证成功及失败。生产 Release 沿用现有真实 mutator。

6. **相册内的基本浏览路由。** 在相册 NavigationStack 增加明确的 collection route，加载实际成员并显示三列网格，使用稳定 ID、惰性网格和有界缩略图。内容页只读，不露出未实现的选择或整理命令；视频显示视频标识与时长，缩略图不可用时保留格子尺寸。已存在的两个队列路由保持不变。相比同时实现完整 A04/A05，此范围满足 A02 点击去向而不引入额外 mutation 行为。

7. **兼容性与性能。** 不替换现有任务、决定或相册归档数据结构，不更改已保存记录；集合路由采用增量 enum case 并检查直接调用者。封面加载复用 `BoundedThumbnailLoader`，不开启 Photos 网络下载。有限访问、目录失败和内容失效都有各自状态。两列布局标题支持多行，保留 16 pt 页边距、6-8 pt 圆角和 44 pt 命令触摸区域。

## Risks / Trade-offs

- PhotoKit 有限访问可能限制可枚举相册：以系统实际返回范围为准，不能以扫描的总相册数补造条目。
- 云端封面未缓存：维持真实数量和固定占位，不为了截图自动下载。
- 同名相册是合法情况：去重基于 id；新建不按名称误认为已有对象。
- 创建返回不明确时直接重试可能产生重复：提供先刷新确认的恢复动作，不自动重放。
- 首次目录仍可能较大：只为可见条目取封面，内容按需加载；测试检查请求次数和取消后的过期结果。
- 这是已有工作区上的增量变更：验证应保留旧队列与 A01 断言，最终报告区分已有失败、新失败与未验证真机行为。

## Migration Plan

确认 proposal/spec/design/tasks 后执行单元基线；先测试集合和新建状态，再接入 UI 和只读内容页。无需数据库迁移。回退展示时保留既有任务/决定，已由用户创建的系统相册不得自动删除。最终运行配置内 Debug/Release 构建、单元/UI 测试、375/393 pt 与大字体截图、只读 reviewer/test_reviewer、OpenSpec 和 Spec workflow validation。
