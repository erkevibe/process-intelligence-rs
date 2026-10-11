# Sprint08: настоящий service oracle и Split Miner

PM /root/pm_s7, P5 после фактического принятия S8-P1. Проверка ограничена текущим доступным окружением и закреплёнными первичными источниками. **Full original service oracle — BLOCKED; genuine Split Miner execution — BLOCKED.** Это результат осуществимости выбранной шестичасовой итерации, а не утверждение, что проекты невозможно собрать вообще. R2-01 и R5-04 остаются OPEN; extracted07 и Alpha+++ не закрывают их.

## Происхождение и контроль

Upstream ApromoreCore commit `bbf24dfd43e72d6992392465f875a4367cbe792b`, настоящий tree `c9f89200ad1170a4aed9711b5174234e7ec2dc18`. Шесть immutable source/build файлов скачаны в приватный SID-only каталог; каждый размер/SHA256/Gitblob проверен. Original EventLogServiceImpl.java из принятого07 использован без редактирования: SHA256 `B1F81927EEB5C020D7260EB75C7A7E4B4182B9DFD6CA3E26EC4AC34F57843527`, blob `f0b3b2687763aa05db888cfaa65a6b24ee312a5b`. SplitMiner.java30111байт SHA256 `78092ab115db5741e3c22de48332a2c488acdd3ed88d408f82e09636f8ec418c`, blob `a1bcb4bff2d6fd46b79ed4cb728f87e09ceab5b3`.

Первичная частная manifest запись ошибочно взяла sha ответа исторического `trees/commit` за настоящий tree. Оригинал сохранён; отдельная коррекция связала primary commit JSON с настоящим c9 tree и заново проверила все шесть blob entries. Ошибочная tree запись не используется как доказательство. Загрузки не повторялись ради переименования этой ошибки. Полные raw source/dependencies не публикуются.

Prospective ACL установлен до сетевых fetch/compile. Два отдельных bounded javac diagnostics сохраняют полные stdout/stderr/exit/time/source/javac hashes. Это по одному настоящему исходному файлу против существующей выборочной OpenXES closure; не full canonical Gradle build, не запуск методов и не доказательство полной dependency supply chain. Ни одного stub, edited upstream, copied fallback class или ложного успешного execution не создано. Старые процессы/установки/БД/настройки не менялись.

## Full original service

[Настоящий Manager build](https://github.com/apromore/ApromoreCore/blob/bbf24dfd43e72d6992392465f875a4367cbe792b/Apromore-Core-Components/Apromore-Manager/build.gradle) требует Database, Storage, Cache, APMLogModule, portal-model, manager-security, plugin API/provider, Event-Log-Plugin-API, Calendar и Commons. Root Gradle добавляет Spring Boot/security/web, Hibernate, Keycloak, Jackson transitives, annotation processing/Lombok и другие зависимости. Существующий06 build содержит только узкую реальную parser/XLog closure и11jar dependencies.

Один javac probe оригинального28508-byte класса завершился exit1: Jackson core/type/databind, Lombok и APMLog отсутствуют уже в первых compiler diagnostics. Общий class compile требует реальных DAO/model/service/storage/calendar типов и generated APIs; подставные типы не доказывают original service. В ограниченном инвентаре готовый Manager артефакт не найден. Gradle/mvn/java/javac в PATH не обнаружены, но закреплённый частный Java11 javac использован по абсолютному пути. Canonical wrapper закрепляет Gradle7.1.1; его bootstrapping и вся closure в этом исследовании не запускались.

Read-only Docker server version завершился exit1: отсутствует DockerDesktopLinuxEngine pipe. Наличие docker.exe не означает доступный daemon/Core. Daemon не запускался, контейнеры/порты/данные не создавались.

Следующий real gate: восстановить canonical source checkout с wrapper/checksummed distribution; закрепить все project/dependency/generated type identities, включая annotation processing; собрать оригинальный Manager без reachable substitutes; выполнить именованный import path в новом изолированном окружении и заморозить outputs. Если выбирается static original-class validateLog как промежуточный gate, он получает только original-class method credit, не full importFromStream/persistence/Portal. Source slices07 остаются отдельным ограниченным доказательством.

## Genuine Split Miner

[Настоящий SplitMiner.java](https://github.com/apromore/ApromoreCore/blob/bbf24dfd43e72d6992392465f875a4367cbe792b/Apromore-Custom-Plugins/SplitMiner-Logic/src/main/java/org/apromore/splitminer/SplitMiner.java) содержит upstream LGPL-3.0-or-later header; не переносится автоматически в MIT runtime. Основной mineBPMNModel использует настоящий LogParser, DFGP frequency/parallelism/filter settings, BPMN transform, gateway helpers, RPST и обработку fallback. Извлечение пары простых LogParser методов не восстанавливает этот алгоритм.

SplitMiner-Logic build зависит от Manager, Zk, Commons, OpenXES, ProcessMining-Collection и de-jbpt0.2.77/uma1.3.1/antlr-rt3.2.0/pnapi-java1.0.5. Реальные imports включают BPMNDiagram/Node/Edge/elements/exporter, DirectlyFollowGraphPlus, DiagramHandler/GatewayMap, Oracle, UI parameter enums и RPST graph types. Один javac probe неизменённого source завершился exit1: BPMN graph model packages отсутствуют в доступной selective closure. Готовый SplitMiner jar в ограниченном инвентаре не найден. No genuine miner invocation/graph output/quality comparison occurred.

Следующий real gate: pin source/dependency closure, включая SupportLibs revision вместо изменяемого master Maven URL; проверить лицензии каждого артефакта; собрать оригинальную selective algorithm closure либо canonical plugin без substitutes; invoke mineBPMNModel на literal noise/concurrency/loop fixtures с явными параметрами; separately compare graph semantics and quality. Пустой main, который только создаёт SplitMiner, не является запуском discovery. Любой новый Rust порт требует отдельного algorithm contract и independent proof.

## Доступная отдельная альтернатива

Прочитан workspace source закреплённого process_mining0.6.2. Case-centric discovery модуль предоставляет `alphappp::full::AlphaPPPConfig` и `alphappp_discover_petri_net`, результат PetriNet плюс AlgoDuration. Это настоящий Alpha+++ API, **другой алгоритм**. Config имеет balance/fitness/replay/loop/skip/DFG thresholds; threshold с названием fitness не является measured model fitness. Token-based replay implementation feature-gated; текущий Cargo default-features=false не подтверждает включённый evaluator. Object-centric footprint fitness/precision также не заменяет case-centric BPMN conformance.

Если отдельный developer успевает после обязательного operational draft и остаётся независимый QA reserve, допустим отдельно защищённый Alpha+++ developer contract с actual fixed corpus/параметрами/PNML или PetriNet result и независимой проверкой. Этот отчёт не реализует/не исполняет Alpha+++ и не объявляет BPMN conversion/fitness/precision подтверждёнными. R4/R5 статусы изменяются только после фактических новых доказательств и explicit selected contract.

## Доказательства и границы

Полный service compiler stderr SHA256 `E786FD1E8CBC4F5947227D5A4BC0B9996BA4031925C1F54200C4C959534A582A`; SplitMiner stderr `F5C3CE625838C0F436C59FD78A456CB819992ED7CAD40B1F7BC10FB024646A2C`; tree binding correction `B212775B2E13E74A180AD069EF2FC38969BB807E4956B681A250EF240970EC2F`. Raw diagnostics сохранены приватно. Комбинированный crate API search tool display был truncated; последующие конкретные source sections и narrow searches используются вместо заявления полного чтения. Первое guessed global cargo source path отсутствовало; настоящий workspace Cargo source затем найден. Инвентарь jar/path bounded, отсутствие hit не доказывает отсутствие артефакта на всей машине.

Feasibility не блокирует безопасные operator preview/IANA потоки. Невозможность полного reference в текущем коротком gate зафиксирована явно; повтор того же compile с тем же classpath не разрешает blocker. Полная конечная [матрица15пунктов](SPRINT_08_SCOPE.md) сохраняется без подмены.
