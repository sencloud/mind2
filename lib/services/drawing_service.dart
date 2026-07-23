import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../util/text_util.dart';
import 'agent/model_client.dart';
import 'document_service.dart';
import 'project_context_builder.dart';
import 'project_service.dart';
import 'settings_service.dart';

/// 画图的「骨架模版」：每套模版对应一种成熟的架构/图形骨架，包含
/// 布局与配色纪律（[guide]）以及一段**可直接渲染的骨架示例**（[example]）。
/// 生成时模型会严格模仿所选骨架的分层/分组/配色，用真实内容替换占位，
/// 从而产出风格统一、专业美观的图（而非杂乱的流程图）。
enum DiagramSkeleton {
  layeredBands,
  microserviceHub,
  dataPipeline,
  hexagonal,
  c4Container,
  threeTier,
  sequence,
  flowchart;

  String get label => switch (this) {
    DiagramSkeleton.layeredBands => '分层色带架构',
    DiagramSkeleton.microserviceHub => '微服务网关星型',
    DiagramSkeleton.dataPipeline => '数据管道流水线',
    DiagramSkeleton.hexagonal => '六边形端口适配器',
    DiagramSkeleton.c4Container => 'C4 容器图',
    DiagramSkeleton.threeTier => '经典三层架构',
    DiagramSkeleton.sequence => '时序图',
    DiagramSkeleton.flowchart => '业务流程图',
  };

  /// UI 里给用户看的一句话说明。
  String get desc => switch (this) {
    DiagramSkeleton.layeredBands => '自上而下的横向色带分层，层内模块并排，重结构、少连线（最像经典架构图）',
    DiagramSkeleton.microserviceHub => '网关/编排居中，微服务集群与数据存储辐射，配套注册/配置/观测',
    DiagramSkeleton.dataPipeline => '从左到右的处理阶段流水线，阶段间以数据流箭头串联',
    DiagramSkeleton.hexagonal => '核心领域居中，入站/出站适配器环绕，外部系统在最外层',
    DiagramSkeleton.c4Container => 'C4 容器级：人、系统边界内的容器、外部系统，标注技术栈与协议',
    DiagramSkeleton.threeTier => '表现层 / 业务逻辑层 / 数据访问层，简洁分块',
    DiagramSkeleton.sequence => '按时间顺序展开一条端到端调用链的参与者与消息',
    DiagramSkeleton.flowchart => '从开始经处理与判定分支到结束的业务流程',
  };

  /// 是否基于 sequenceDiagram（语法纪律不同于 flowchart）。
  bool get isSequence => this == DiagramSkeleton.sequence;

  /// 给模型的骨架与风格纪律。
  String get guide => switch (this) {
    DiagramSkeleton.layeredBands =>
      '分层色带架构：用 flowchart TB。自上而下把系统划分为若干「层」（如 展现层 / 通讯层 / 服务层 / 数据层 等，'
          '按真实系统调整）。每层用一个 subgraph 作为一条横向色带；层内写一行 `direction LR`，'
          '并用**隐形连线 `~~~` 把该层节点依次串起来**（如 `A ~~~ B ~~~ C`）强制排成一行（隐形连线不显示箭头）。'
          '整层同色（同一 classDef），层与层之间只用一条主干箭头相连表达自上而下的依赖；'
          '**不要在模块之间画细碎的交叉连线**——本模版靠分组与色带表达结构，不靠箭头。',
    DiagramSkeleton.microserviceHub =>
      '微服务网关星型：用 flowchart TB。顶部客户端 → 中间 API 网关（路由/鉴权/限流）→ 微服务集群（一个 subgraph 内多个服务）→ '
          '底部各自的数据存储；旁路一个 subgraph 放注册中心/配置中心/链路追踪等治理与观测组件。'
          '箭头表达调用与依赖，治理类用虚线（`-. 文字 .->`）。',
    DiagramSkeleton.dataPipeline =>
      '数据管道流水线：用 flowchart LR。从左到右依次是 数据源 → 采集/接入 → 处理/计算 → 存储 → 服务/应用，'
          '每个阶段一个 subgraph，阶段之间用带标注的箭头表达数据流向，阶段内并排列出该阶段的组件。',
    DiagramSkeleton.hexagonal =>
      '六边形（端口与适配器）：用 flowchart TB。中间是核心领域（应用服务/领域模型/端口），'
          '上方入站适配器（REST/消息消费者等），下方出站适配器（持久化/消息发布/外部客户端），最外层是外部系统。'
          '箭头方向体现「外→核心→外」的依赖倒置。',
    DiagramSkeleton.c4Container =>
      'C4 容器图：用 flowchart TB。用「人 / 系统 / 容器 / 外部系统」四类要素；把本系统的各容器（如 SPA、API、数据库）'
          '放进一个代表系统边界的 subgraph，容器标签里用 «Container: 技术栈» 注明技术，'
          '关系箭头标注交互方式与协议（如 JSON/HTTPS、JDBC、SMTP）。',
    DiagramSkeleton.threeTier =>
      '经典三层架构：用 flowchart TB。自上而下 表现层 → 业务逻辑层 → 数据访问层 三个 subgraph，'
          '最底部接数据库；层内并排列出典型组件，层间用箭头表达调用方向。',
    DiagramSkeleton.sequence =>
      '时序图：用 sequenceDiagram。选择系统最核心的一条端到端调用链，声明关键参与者（participant，用简短英文别名 + 中文显示名），'
          '按时间顺序展开同步（->>）/异步/返回（-->>）消息，必要时用 alt/opt/loop 表达分支与循环。',
    DiagramSkeleton.flowchart =>
      '业务流程图：用 flowchart TD。从「开始」节点出发，经关键处理步骤（矩形）与判定分支（菱形 `{"..."}`），'
          '到「结束」节点，覆盖主流程与重要异常/分支路径；判定分支的箭头用 `|"是"|` / `|"否"|` 标注。',
  };

  /// 一段可正确渲染的骨架示例——模型须严格模仿其结构/分组/配色，用真实内容替换。
  String get example => switch (this) {
    DiagramSkeleton.layeredBands => '''
flowchart TB
  subgraph present["展现层"]
    direction LR
    Web["Web<br/>(HTML5/Vue)"]
    App["App<br/>(iOS/Android)"]
    Mini["小程序/公众号"]
    Rest["Restful 接口"]
    Web ~~~ App ~~~ Mini ~~~ Rest
  end
  subgraph comm["通讯层"]
    direction LR
    Cdn["CDN"]
    Slb["SLB"]
    Netty["Netty"]
    Http["HTTP/HTTPS"]
    Cdn ~~~ Slb ~~~ Netty ~~~ Http
  end
  subgraph service["服务层"]
    direction LR
    Gateway["网关 Zuul"]
    SvcA["业务服务 A"]
    SvcB["业务服务 B"]
    Config["配置中心"]
    Gateway ~~~ SvcA ~~~ SvcB ~~~ Config
  end
  subgraph data["数据层"]
    direction LR
    Mongo[("MongoDB")]
    Mysql[("MySQL")]
    Es[("ElasticSearch")]
    Mongo ~~~ Mysql ~~~ Es
  end
  present --> comm
  comm --> service
  service --> data
  classDef presentCls fill:#00bcd4,stroke:#00838f,color:#ffffff,stroke-width:2px;
  classDef commCls fill:#b2ebf2,stroke:#00838f,color:#004d40,stroke-width:2px;
  classDef serviceCls fill:#c5cae9,stroke:#3949ab,color:#1a237e,stroke-width:2px;
  classDef dataCls fill:#ffcc80,stroke:#ef6c00,color:#e65100,stroke-width:2px;
  class Web,App,Mini,Rest presentCls;
  class Cdn,Slb,Netty,Http commCls;
  class Gateway,SvcA,SvcB,Config serviceCls;
  class Mongo,Mysql,Es dataCls;''',
    DiagramSkeleton.microserviceHub => '''
flowchart TB
  subgraph clients["客户端"]
    direction LR
    WebC["Web"]
    MobileC["移动端"]
    WebC ~~~ MobileC
  end
  Gateway["API 网关<br/>路由/鉴权/限流"]
  subgraph svcs["微服务集群"]
    direction LR
    UserSvc["用户服务"]
    OrderSvc["订单服务"]
    PaySvc["支付服务"]
    UserSvc ~~~ OrderSvc ~~~ PaySvc
  end
  subgraph infra["治理与观测"]
    direction TB
    Registry["注册中心"]
    ConfigC["配置中心"]
    Trace["链路追踪"]
    Registry ~~~ ConfigC ~~~ Trace
  end
  subgraph stores["数据存储"]
    direction LR
    UserDB[("用户库")]
    OrderDB[("订单库")]
    Cache[("Redis 缓存")]
    UserDB ~~~ OrderDB ~~~ Cache
  end
  clients --> Gateway
  Gateway --> UserSvc
  Gateway --> OrderSvc
  Gateway --> PaySvc
  svcs -. 注册/配置 .-> infra
  UserSvc --> UserDB
  OrderSvc --> OrderDB
  PaySvc --> Cache
  classDef cli fill:#e3f2fd,stroke:#1565c0,color:#0d47a1,stroke-width:2px;
  classDef gw fill:#fff3e0,stroke:#ef6c00,color:#e65100,stroke-width:2px;
  classDef svc fill:#e8f5e9,stroke:#2e7d32,color:#1b5e20,stroke-width:2px;
  classDef inf fill:#ede7f6,stroke:#5e35b1,color:#311b92,stroke-width:2px;
  classDef db fill:#fce4ec,stroke:#c2185b,color:#880e4f,stroke-width:2px;
  class WebC,MobileC cli;
  class Gateway gw;
  class UserSvc,OrderSvc,PaySvc svc;
  class Registry,ConfigC,Trace inf;
  class UserDB,OrderDB,Cache db;''',
    DiagramSkeleton.dataPipeline => '''
flowchart LR
  subgraph src["数据源"]
    direction TB
    Log["日志"]
    BizDB["业务库"]
    ExtApi["第三方 API"]
    Log ~~~ BizDB ~~~ ExtApi
  end
  subgraph ingest["采集接入"]
    Kafka["消息队列<br/>Kafka"]
  end
  subgraph compute["处理与计算"]
    direction TB
    Stream["实时计算<br/>Flink"]
    Batch["离线计算<br/>Spark"]
    Stream ~~~ Batch
  end
  subgraph store["存储"]
    direction TB
    Dw[("数据仓库")]
    Olap[("OLAP 引擎")]
    Dw ~~~ Olap
  end
  subgraph serve["服务与应用"]
    direction TB
    Bi["报表 BI"]
    Rec["推荐服务"]
    Bi ~~~ Rec
  end
  src -->|"采集"| ingest
  ingest -->|"分发"| compute
  compute -->|"落库"| store
  store -->|"查询"| serve
  classDef s1 fill:#e1f5fe,stroke:#0277bd,color:#01579b,stroke-width:2px;
  classDef s2 fill:#fff8e1,stroke:#ff8f00,color:#e65100,stroke-width:2px;
  classDef s3 fill:#e8f5e9,stroke:#2e7d32,color:#1b5e20,stroke-width:2px;
  classDef s4 fill:#f3e5f5,stroke:#7b1fa2,color:#4a148c,stroke-width:2px;
  classDef s5 fill:#fce4ec,stroke:#c2185b,color:#880e4f,stroke-width:2px;
  class Log,BizDB,ExtApi s1;
  class Kafka s2;
  class Stream,Batch s3;
  class Dw,Olap s4;
  class Bi,Rec s5;''',
    DiagramSkeleton.hexagonal => '''
flowchart TB
  subgraph inbound["入站适配器"]
    direction LR
    RestIn["REST 控制器"]
    MqIn["消息消费者"]
    RestIn ~~~ MqIn
  end
  subgraph core["核心领域"]
    direction LR
    AppSvc["应用服务<br/>用例编排"]
    Domain["领域模型<br/>实体/聚合"]
    Ports["端口<br/>接口定义"]
    AppSvc ~~~ Domain ~~~ Ports
  end
  subgraph outbound["出站适配器"]
    direction LR
    RepoOut["持久化适配器"]
    MqOut["消息发布者"]
    ApiOut["外部 API 客户端"]
    RepoOut ~~~ MqOut ~~~ ApiOut
  end
  subgraph external["外部系统"]
    direction LR
    Db[("数据库")]
    Broker["消息中间件"]
    ThirdParty["第三方服务"]
    Db ~~~ Broker ~~~ ThirdParty
  end
  inbound -->|"调用用例"| core
  core -->|"经由端口"| outbound
  outbound --> external
  classDef inb fill:#e3f2fd,stroke:#1565c0,color:#0d47a1,stroke-width:2px;
  classDef cor fill:#fff3e0,stroke:#ef6c00,color:#e65100,stroke-width:2px;
  classDef outb fill:#e8f5e9,stroke:#2e7d32,color:#1b5e20,stroke-width:2px;
  classDef ext fill:#eceff1,stroke:#546e7a,color:#263238,stroke-width:2px;
  class RestIn,MqIn inb;
  class AppSvc,Domain,Ports cor;
  class RepoOut,MqOut,ApiOut outb;
  class Db,Broker,ThirdParty ext;''',
    DiagramSkeleton.c4Container => '''
flowchart TB
  User["用户<br/>«Person»"]
  subgraph system["订单系统 «System»"]
    direction TB
    Spa["Web 单页应用<br/>«Container: Vue»"]
    ApiApp["应用 API<br/>«Container: Spring Boot»"]
    Db[("数据库<br/>«Container: PostgreSQL»")]
    Spa -->|"JSON/HTTPS"| ApiApp
    ApiApp -->|"读写 JDBC"| Db
  end
  Email["邮件系统<br/>«External»"]
  Pay["支付平台<br/>«External»"]
  User -->|"使用 HTTPS"| Spa
  ApiApp -->|"发送邮件 SMTP"| Email
  ApiApp -->|"发起支付 API"| Pay
  classDef person fill:#08427b,stroke:#052e56,color:#ffffff,stroke-width:2px;
  classDef container fill:#1168bd,stroke:#0b4884,color:#ffffff,stroke-width:2px;
  classDef ext fill:#999999,stroke:#6b6b6b,color:#ffffff,stroke-width:2px;
  class User person;
  class Spa,ApiApp,Db container;
  class Email,Pay ext;''',
    DiagramSkeleton.threeTier => '''
flowchart TB
  subgraph presentation["表现层"]
    direction LR
    Ui["页面/视图"]
    Controller["控制器"]
    Ui ~~~ Controller
  end
  subgraph business["业务逻辑层"]
    direction LR
    Service["业务服务"]
    DomainLogic["领域逻辑"]
    Service ~~~ DomainLogic
  end
  subgraph dataAccess["数据访问层"]
    direction LR
    Dao["DAO/Repository"]
    Orm["ORM 映射"]
    Dao ~~~ Orm
  end
  Db[("数据库")]
  presentation -->|"调用"| business
  business -->|"访问"| dataAccess
  dataAccess -->|"SQL"| Db
  classDef pres fill:#e3f2fd,stroke:#1565c0,color:#0d47a1,stroke-width:2px;
  classDef biz fill:#e8f5e9,stroke:#2e7d32,color:#1b5e20,stroke-width:2px;
  classDef dao fill:#fff3e0,stroke:#ef6c00,color:#e65100,stroke-width:2px;
  classDef dbCls fill:#f3e5f5,stroke:#7b1fa2,color:#4a148c,stroke-width:2px;
  class Ui,Controller pres;
  class Service,DomainLogic biz;
  class Dao,Orm dao;
  class Db dbCls;''',
    DiagramSkeleton.sequence => '''
sequenceDiagram
  autonumber
  participant U as 用户
  participant W as Web 前端
  participant G as API 网关
  participant S as 订单服务
  participant D as 数据库
  U->>W: 提交订单
  W->>G: POST /orders
  G->>S: 转发请求
  S->>D: 写入订单
  D-->>S: 返回主键
  S-->>G: 订单结果
  G-->>W: 200 OK
  W-->>U: 展示下单成功''',
    DiagramSkeleton.flowchart => '''
flowchart TD
  Start(["开始"]) --> Input["接收用户请求"]
  Input --> Check{"参数是否合法"}
  Check -->|"否"| Reject["返回错误提示"]
  Check -->|"是"| Process["执行业务处理"]
  Process --> Save["写入数据库"]
  Save --> Notify["发送通知"]
  Notify --> End(["结束"])
  Reject --> End
  classDef startEnd fill:#e8f5e9,stroke:#2e7d32,color:#1b5e20,stroke-width:2px;
  classDef step fill:#e3f2fd,stroke:#1565c0,color:#0d47a1,stroke-width:2px;
  classDef decision fill:#fff3e0,stroke:#ef6c00,color:#e65100,stroke-width:2px;
  class Start,End startEnd;
  class Input,Process,Save,Notify,Reject step;
  class Check decision;''',
  };

  static DiagramSkeleton fromName(String? name) =>
      DiagramSkeleton.values.firstWhere(
        (e) => e.name == name,
        orElse: () => DiagramSkeleton.layeredBands,
      );
}

/// 画图关联的工程（真实工程目录）。
class DrawingProjectRef {
  DrawingProjectRef({required this.path});

  final String path;

  String get name => path.isEmpty ? '' : p.basename(path);

  Map<String, dynamic> toJson() => {'path': path};

  factory DrawingProjectRef.fromJson(Map<String, dynamic> json) =>
      DrawingProjectRef(path: json['path'] as String? ?? '');
}

/// 一张图：主题需求 + 关联工程 + 图种 + Mermaid 源码 + 渲染 PNG。
class DrawingDoc {
  DrawingDoc({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.prompt = '',
    this.skeleton = DiagramSkeleton.layeredBands,
    List<DrawingProjectRef>? linkedProjects,
    this.mermaid = '',
    this.imagePath = '',
    this.summary = '',
  }) : linkedProjects = linkedProjects ?? [];

  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;

  /// 画图需求 / 补充说明（可选，指导重点与取舍）。
  String prompt;

  /// 选用的骨架模版，决定图的骨架布局与配色风格。
  DiagramSkeleton skeleton;

  /// 关联的工程（可 1 个或多个组合），用于据真实代码结构出图。
  List<DrawingProjectRef> linkedProjects;

  /// 生成/编辑后的 Mermaid 源码。
  String mermaid;

  /// 渲染出的 PNG 绝对路径（可能为空，表示未渲染或渲染失败）。
  String imagePath;

  /// 对该图的一句话说明（模型给出）。
  String summary;

  bool get hasImage =>
      imagePath.trim().isNotEmpty && File(imagePath).existsSync();
  bool get hasMermaid => mermaid.trim().isNotEmpty;
  String get linkedNames =>
      linkedProjects.map((e) => e.name).where((e) => e.isNotEmpty).join('、');

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'prompt': prompt,
    'skeleton': skeleton.name,
    'linkedProjects': linkedProjects.map((e) => e.toJson()).toList(),
    'mermaid': mermaid,
    'imagePath': imagePath,
    'summary': summary,
  };

  factory DrawingDoc.fromJson(Map<String, dynamic> json) => DrawingDoc(
    id: json['id'] as String,
    title: json['title'] as String? ?? '未命名图',
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
    prompt: json['prompt'] as String? ?? '',
    skeleton: DiagramSkeleton.fromName(json['skeleton'] as String?),
    linkedProjects: ((json['linkedProjects'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => DrawingProjectRef.fromJson(e.cast<String, dynamic>()))
        .toList(),
    mermaid: json['mermaid'] as String? ?? '',
    imagePath: json['imagePath'] as String? ?? '',
    summary: json['summary'] as String? ?? '',
  );
}

/// 「画图」业务：据关联工程（真实代码结构）用大模型产出漂亮、完整的架构图
/// （Mermaid），再本地渲染成高清 PNG。
class DrawingService extends ChangeNotifier {
  DrawingService(this.settings, {this.project, required this.document});

  final SettingsService settings;

  /// 项目服务（桌面端），用于列出最近打开的工程供快速关联；移动端为空。
  final ProjectService? project;

  /// 复用文档服务的 Mermaid → PNG 渲染管线（本机无头浏览器）。
  final DocumentService document;

  List<String> get recentProjects => project?.projects ?? const [];

  final List<DrawingDoc> docs = [];
  DrawingDoc? current;
  bool busy = false;
  String stage = '';

  /// 关联工程上下文注入 prompt 的总长度上限，避免超出模型上下文。
  static const _maxContextChars = 60000;

  bool _cancel = false;
  File? _store;
  Directory? _assetDir;

  late final ProjectContextBuilder _ctx = ProjectContextBuilder(settings);

  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _store = File(p.join(dir.path, 'drawings.json'));
    _assetDir = Directory(p.join(dir.path, 'drawing_assets'));
    try {
      await _assetDir!.create(recursive: true);
    } catch (_) {}
    if (await _store!.exists()) {
      try {
        final data = jsonDecode(await _store!.readAsString());
        if (data is List) {
          docs
            ..clear()
            ..addAll(
              data.whereType<Map>().map(
                (e) => DrawingDoc.fromJson(e.cast<String, dynamic>()),
              ),
            );
          docs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        }
      } catch (_) {}
    }
  }

  DrawingDoc create({
    String title = '',
    String prompt = '',
    DiagramSkeleton skeleton = DiagramSkeleton.layeredBands,
    List<String> projectPaths = const [],
  }) {
    final now = DateTime.now();
    final doc = DrawingDoc(
      id: now.microsecondsSinceEpoch.toString(),
      title: title.trim().isEmpty ? '未命名图' : title.trim(),
      createdAt: now,
      updatedAt: now,
      prompt: prompt.trim(),
      skeleton: skeleton,
      linkedProjects: [
        for (final path in projectPaths.toSet()) DrawingProjectRef(path: path),
      ],
    );
    docs.insert(0, doc);
    current = doc;
    notifyListeners();
    _persist();
    return doc;
  }

  void open(DrawingDoc doc) {
    current = doc;
    notifyListeners();
  }

  void close() {
    current = null;
    notifyListeners();
  }

  Future<void> delete(DrawingDoc doc) async {
    docs.remove(doc);
    if (current == doc) current = null;
    if (doc.imagePath.isNotEmpty) {
      try {
        final f = File(doc.imagePath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    notifyListeners();
    await _persist();
  }

  Future<void> save() async {
    final doc = current;
    if (doc == null) return;
    doc.updatedAt = DateTime.now();
    docs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    notifyListeners();
    await _persist();
  }

  void addLinkedProject(String path) {
    final doc = current;
    if (doc == null) return;
    final normalized = path.trim();
    if (normalized.isEmpty) return;
    if (doc.linkedProjects.any((e) => e.path == normalized)) return;
    doc.linkedProjects.add(DrawingProjectRef(path: normalized));
    doc.updatedAt = DateTime.now();
    notifyListeners();
    _persist();
  }

  void removeLinkedProject(String path) {
    final doc = current;
    if (doc == null) return;
    doc.linkedProjects.removeWhere((e) => e.path == path);
    doc.updatedAt = DateTime.now();
    notifyListeners();
    _persist();
  }

  void setSkeleton(DiagramSkeleton skeleton) {
    final doc = current;
    if (doc == null) return;
    doc.skeleton = skeleton;
    doc.updatedAt = DateTime.now();
    notifyListeners();
    _persist();
  }

  /// 生成图：据关联工程真实代码结构 + 需求，用大模型产出漂亮完整的 Mermaid，
  /// 再渲染成 PNG。无关联工程时，仅据主题/需求出图。
  Future<void> generate([DrawingDoc? target]) async {
    final doc = target ?? current;
    if (doc == null || busy) return;
    _begin('正在准备…');
    try {
      final paths = doc.linkedProjects
          .map((e) => e.path)
          .where((e) => e.trim().isNotEmpty)
          .toList();
      var context = '';
      if (paths.isNotEmpty) {
        stage = '正在读取工程结构与代码…';
        notifyListeners();
        context = await _ctx.buildPack(
          paths,
          doc.prompt.isEmpty ? doc.title : doc.prompt,
          log: (line) {
            stage = line.trim();
            notifyListeners();
          },
        );
      }
      if (_cancel) return;
      stage = '正在设计${doc.skeleton.label}…';
      notifyListeners();
      final result = await _designDiagram(doc, context);
      if (_cancel) return;
      doc.mermaid = result.$1;
      if (result.$2.trim().isNotEmpty) doc.summary = result.$2.trim();
      doc.updatedAt = DateTime.now();
      notifyListeners();
      await _persist();

      stage = '正在渲染高清图…';
      notifyListeners();
      await _render(doc);
      stage = doc.hasImage ? '已生成${doc.skeleton.label}' : '已生成图定义（未能渲染为图片，可查看/编辑源码）';
      await _persist();
    } catch (e) {
      stage = _cancel ? '已停止' : '生成失败：$e';
    } finally {
      if (_cancel) stage = '已停止';
      _end();
    }
  }

  /// 停止正在进行的生成（仅对大模型设计阶段有效；渲染阶段无法中断）。
  void cancel() {
    if (!busy) return;
    _cancel = true;
    stage = '正在停止…';
    notifyListeners();
  }

  /// 用当前 Mermaid 源码重新渲染 PNG（用于手动编辑源码后刷新）。
  Future<void> rerender([DrawingDoc? target]) async {
    final doc = target ?? current;
    if (doc == null || busy) return;
    if (!doc.hasMermaid) {
      stage = '暂无图定义可渲染';
      notifyListeners();
      return;
    }
    _begin('正在渲染高清图…');
    try {
      await _render(doc);
      stage = doc.hasImage ? '已渲染' : '渲染失败：请检查 Mermaid 源码或本机浏览器（Edge/Chrome）';
      await _persist();
    } catch (e) {
      stage = '渲染失败：$e';
    } finally {
      _end();
    }
  }

  Future<void> _render(DrawingDoc doc) async {
    final png = await document.renderMermaidPng(doc.mermaid);
    if (png == null) {
      doc.imagePath = '';
      return;
    }
    final dir = _assetDir;
    if (dir == null) return;
    final out = File(p.join(dir.path, '${doc.id}.png'));
    await out.writeAsBytes(png, flush: true);
    doc.imagePath = out.path;
    doc.updatedAt = DateTime.now();
  }

  Future<(String, String)> _designDiagram(DrawingDoc doc, String context) async {
    final reply = await ModelClient(settings, role: ModelRole.writing).complete(
      system:
          '你是资深软件架构师与图形设计专家。你依据给定的真实工程信息与需求，产出一张既专业又美观、'
          '结构完整的架构图（Mermaid）。你严格使用合法 Mermaid 语法，不臆造工程中不存在的模块。'
          '只输出一个 JSON 对象，不要解释、不要代码围栏。',
      user: _designPrompt(doc, context),
      jsonMode: true,
      isCancelled: () => _cancel,
    );
    final obj = ModelClient.parseJsonObject(reply);
    var mermaid = (obj['mermaid'] ?? '').toString();
    mermaid = _cleanMermaid(mermaid);
    if (mermaid.trim().isEmpty) throw Exception('模型未返回有效的 Mermaid 图定义');
    final summary = (obj['summary'] ?? '').toString();
    return (mermaid, summary);
  }

  String _designPrompt(DrawingDoc doc, String context) {
    final ctxBlock = context.trim().isEmpty
        ? '（未关联工程，请依据主题与需求，产出一张合理、通用且完整的图）'
        : _clip(context, _maxContextChars);
    final needBlock = doc.prompt.trim().isEmpty
        ? ''
        : '\n【额外需求 / 侧重点】\n${doc.prompt.trim()}\n';
    final sk = doc.skeleton;
    return '''
请为主题「${doc.title}」设计一张图，**严格采用「${sk.label}」骨架模版的风格**，用 Mermaid 表达。

【骨架与风格要求（${sk.label}）】
${sk.guide}
$needBlock
【出图质量要求——务必做到漂亮、完整、专业】
- 忠于骨架：分层/分组、方向、配色都要遵循下方骨架示例的组织方式，只把占位内容替换为主题/工程的真实内容。
- 结构完整：覆盖该图应有的关键要素与关系，不遗漏主干；节点数量控制在 12~28 个之间，既充实又不杂乱。
- 少而准的连线：优先用 subgraph 分组表达结构；**只保留能表达真实依赖/调用/数据流的必要连线，坚决避免细碎、交叉、无意义的箭头**。
- 美观配色：沿用骨架里的 classDef 配色思路（每组语义色柔和、对比清晰、专业），同一分组同色。
- 可读排版：显式方向；显示文字用中文、简洁。
${_syntaxRules(sk)}
请严格参照下面这段**可正确渲染**的「${sk.label}」骨架示例（仅示意结构与风格，请用真实内容替换占位）：
${sk.example}

只输出一个 JSON 对象（无围栏、无多余文字）：
{"mermaid":"<完整 mermaid 源码>","summary":"<一句话说明这张图画了什么>"}

【工程信息（真实、供你据实出图）】
$ctxBlock
''';
  }

  /// 按骨架类型给出对应的 Mermaid 语法纪律（时序图与 flowchart 规则不同）。
  static String _syntaxRules(DiagramSkeleton sk) {
    if (sk.isSequence) {
      return '''
Mermaid 语法纪律（sequenceDiagram，必须严格遵守，否则会渲染失败）：
- 第一行是 `sequenceDiagram`。
- 参与者用 `participant 别名 as 中文显示名`，别名只用英文字母/数字。
- 消息用 `A->>B: 中文说明`（同步）、`A-->>B: 中文说明`（返回）；分支/循环用 `alt/opt/loop … end`。
- 不要 classDef/class、不要 subgraph、不要 HTML 标签与 emoji。
''';
    }
    return '''
Mermaid 语法纪律（flowchart，必须严格遵守，否则会渲染失败）：
- 第一行是图类型与方向，如 `flowchart TB` 或 `flowchart LR`。
- 所有 **节点 id 和 subgraph id 只用英文字母/数字、无空格、无中文**；中文只出现在“显示标签”里。
- **每个节点标签一律用英文双引号包裹**：如 `A["用户交互层"]`、圆柱体 `DB[("关系数据库<br/>MySQL")]`、判定 `C{"是否合法"}`；标签内换行只用 `<br/>`（且必须在引号内）。
- **样式一律用行末的 `class` 语句成组应用，禁止使用行内 `:::` 写法**：即 `class 节点id1,节点id2 类名;`。
- subgraph 写法：`subgraph sgId["中文标题"]` … 内容 … `end`；需要层内并排/成列时在其内写一行 `direction LR`（或 `TB`）。
- **重要**：subgraph 内若节点之间没有真实连线，`direction` 不会生效，节点会错位堆叠。此时必须用**隐形连线 `~~~`** 按目标顺序把它们串起来（如 `A ~~~ B ~~~ C`）来强制排布；`~~~` 不显示箭头。
- 不要 click 语句、不要除 `<br/>` 外的 HTML 标签、不要 emoji。
''';
  }

  /// 去掉模型可能残留的 ```mermaid 围栏。
  static String _cleanMermaid(String raw) {
    var s = raw.trim();
    final fence = RegExp(r'^```(?:mermaid)?\s*([\s\S]*?)\s*```$').firstMatch(s);
    if (fence != null) s = fence.group(1)!.trim();
    return s;
  }

  static String _clip(String s, int max) =>
      clip(s, max, suffix: '\n…（内容过长已截断）');

  void _begin(String message) {
    busy = true;
    _cancel = false;
    stage = message;
    notifyListeners();
  }

  void _end() {
    busy = false;
    notifyListeners();
  }

  Future<void> _persist() async {
    if (_store == null) return;
    try {
      await _store!.writeAsString(
        jsonEncode(docs.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }
}
