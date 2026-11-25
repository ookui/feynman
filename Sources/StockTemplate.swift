import SwiftUI

enum StockModule: String, CaseIterable {
    case summary, thesis, profile, business, kpis, management, earnings, valuation, risks, catalysts, updates, questions, decisions, references

    private var metadata: (String, String, String, PageCategory) {
        switch self {
        case .summary: return ("一页纸结论","每次更新必改","doc.text",.project)
        case .thesis: return ("投资逻辑（当前版本）","认知变化时改写","text.book.closed",.memo)
        case .profile: return ("公司概况与商业模式","低频","building.2",.stock)
        case .business: return ("业务拆分 Segments","季度","square.grid.2x2",.kind(.entities))
        case .kpis: return ("KPI 仪表盘","季度","gauge.with.dots.needle.50percent",.kind(.concepts))
        case .management: return ("管理层、资本配置与股东结构","低频 + 事件","person.3",.stock)
        case .earnings: return ("财务模型","季度","chart.line.uptrend.xyaxis",.report)
        case .valuation: return ("估值分析","季度 + 大幅波动时","function",.kind(.entities))
        case .risks: return ("风险清单","季度","exclamationmark.triangle",.kind(.questions))
        case .catalysts: return ("催化剂日历","事件驱动","calendar",.kind(.events))
        case .updates: return ("重大事件跟踪","事件驱动，只追加","clock.arrow.circlepath",.kind(.events))
        case .questions: return ("待解决问题","持续","questionmark.circle",.kind(.questions))
        case .decisions: return ("决策日志","只追加，不改写","list.bullet.rectangle",.log)
        case .references: return ("References","持续","folder",.kind(.references))
        }
    }
    var title: String { metadata.0 }
    var cadence: String { metadata.1 }
    var symbol: String { metadata.2 }
    var category: PageCategory { metadata.3 }
    var heading: String { Self.allCases.firstIndex(of: self).map { String($0) + ". " + title } ?? title }
    var appendOnly: Bool { self == .updates || self == .decisions }
    var destination: Place { .stock(self) }
    var note: String? {
        switch self {
        case .business: return "analysis/business.md"
        case .earnings: return "analysis/growth.md"
        default: return "analysis/" + rawValue + ".md"
        }
    }

    var template: String {
        let fields: String
        switch self {
        case .summary:
            fields = """
            - 一句话定位（例：以肿瘤基因检测获取临床与分子数据，通过数据授权和 AI 产品变现的平台）
            - 核心逻辑（≤3 条）
            - 市场隐含预期：一致预期收入、利润，反向 DCF 隐含的长期增速、利润率
            - 我的预期差：与市场的具体分歧及对应变量
            - 证伪条件：出现什么数据即认错
            - 估值结论：情景加权目标价、当前价、潜在空间
            - 下一个催化剂：日期、事件、预期
            """
        case .thesis:
            fields = """
            ### 1.1 Thesis 支柱
            | 支柱 | 内容 | 依据 | 验证指标 | 当前状态（成立/待验证/走弱） |
            ### 1.2 Bull / Base / Bear 叙事
            ### 1.3 证伪条件与跟踪阈值
            | 条件 | 阈值 | 数据来源 | 检查频率 |
            """
        case .profile:
            fields = """
            - 发展历程与关键转折（IPO、重大并购、战略转向）
            - 价值链位置：客户是谁、谁付钱、付费逻辑（检测报销 vs 药企数据采购）
            - 飞轮 / 单位经济：单次检测收入、成本、毛利，新增数据的变现方式
            - 护城河：数据规模、监管资质（FDA/ADLT）、医院网络、转换成本
            """
        case .business:
            fields = """
            ### 3.x [分部名]（例：Genomics — 肿瘤 / 遗传 Ambry；Data & Services — Insights 数据授权、AI 应用）
            - 业务简介与流程
            - 收入驱动拆解：量 × 价（检测量 × ASP；合同数 × 合同金额）
            | 指标 | FY-2 | FY-1 | FY0 | 增速 | 占比 | 毛利率 |
            - 竞争格局：主要对手、份额、差异点（例：Guardant、Foundation Medicine、Caris、Natera）
            - TAM / SAM / SOM 及推导过程，写明口径和假设
            - 分部之间的联动关系
            """
        case .kpis:
            fields = """
            | KPI | Q-4 | Q-3 | Q-2 | Q-1 | 最新 | 同比 | 与 thesis 关系 |
            例：肿瘤检测量、遗传检测量、数据授权合同余额、Data & Services 增速、毛利率、调整后 EBITDA、经营现金流。
            """
        case .management:
            fields = """
            - 创始人及核心管理层的背景、持股、激励方案
            - SBC 占收入比、稀释率、GAAP 与调整后口径的差异
            - 资产负债表：现金、债务、可转债条款及到期日、融资需求
            - 并购历史与整合效果
            - 主要股东、内部人交易、空头比例
            """
        case .earnings:
            fields = """
            - 模型链接：[model.xlsx](link)
            - 关键假设与第 3、4 节驱动因素逐一对应
            | 假设 | Bear | Base | Bull | 一致预期 | 依据 |
            - 预测摘要：收入、毛利、费用率、EBITDA、FCF、盈亏平衡时点
            - 与一致预期的差异及原因
            - 敏感性：对价值影响最大的两三个变量
            """
        case .valuation:
            fields = """
            - DCF / EV/Sales / EV/Gross Profit 的选用理由
            - 可比公司表；反向 DCF 中当前价格隐含的预期；历史估值区间
            - 情景加权目标价
            | 情景 | 概率 | 目标价 | 关键假设 |
            """
        case .risks:
            fields = "| 风险 | 类型（经营/监管/报销/竞争/融资/治理） | 概率 | 影响 | 监测信号 |"
        case .catalysts:
            fields = "| 日期 | 事件 | 预期 | 影响的支柱/假设 |\n例：季报、FDA 审批、Medicare 定价/覆盖决定、大额数据合同、可转债到期。"
        case .updates:
            fields = "| 日期 | 事件 | 影响的 thesis 支柱 / 模型假设 | 调整动作 | 来源 |"
        case .questions:
            fields = "| # | 问题 | 为什么重要（影响哪个判断） | 现有证据 | 状态 |"
        case .decisions:
            fields = "| 日期 | 价格 | 动作（建仓/加仓/减仓/清仓/观望） | 当时的逻辑 | 当时的估值判断 | 事后复盘 |"
        case .references:
            fields = "- 公司披露：10-K / 10-Q / 业绩电话会 / 投资者日\n- 卖方研报、专家访谈、渠道调研\n- LakeHouse 内相关文件：[name](link)"
        }
        return "## " + heading + " 〔" + cadence + "〕\n" + fields
    }
}
