# Рабочее состояние ProcessMining

## Sprint34: установка на предоставленный LAN-сервер

Новое окно пользователя: 25.10.2026 08:44:58–16:44:58 UTC
(13:44:58–21:44:58 Asia/Qyzylorda). Предыдущее окно завершено, не продолжается.
Ветка `codex/sprint-34-lan-operations` от принятого main14a75e3.
Принятый бинарник c9440eb/0.11.0 установлен на Ubuntu24.04/LXC; manifest1267
и GitHub ZIP сверены. PostgreSQL18.6 UTF8, schema6, Caddy2.11.7, службы
systemd и LAN-firewall работают. Rust-код не менялся.

38 целевых проверок/58 запросов, полный BPMN roundtrip, numeric replay,
restart/persistence, полная копия и восстановление в отдельную базу прошли.
Проверены запуск восстановленной базы, отказ pg_dump, SIGKILL backup-процесса
с восстановлением app через ExecStopPost, согласованный restart PostgreSQL.
Импорт100000events/20000cases прошёл; BPMN по-прежнему64cases/500events.
Ежедневная копия03:00Asia/Qyzylorda,14завершённых копий; первая off-host
копия на защищённом каталоге PC сверена. Регулярный off-host транспорт не задан.

Точка продолжения `.local/server-deploy-20261025/checkpoint.json`.
Доступ и секреты в защищённом `C:/Users/alikh/.codex/private-server-access`,
содержимое не публиковать. Ключ id_baurfax исключён локальным Git exclude.
Ожидается пользовательское подтверждение Windows CA; браузер без доверия
закономерно ERR_CERT_AUTHORITY_INVALID, обход проверки не применяется.
Пользовательский сервис3131 и прежние локальные PG/app не трогать.
Отчёт [SPRINT_34_REPORT.md](SPRINT_34_REPORT.md),
эксплуатация [LINUX_LAN_OPERATIONS.md](LINUX_LAN_OPERATIONS.md).

## Sprint33: реальный DDL-переход v5→v6 под обычной ролью

PR45 принят в maincb22669c: точныйddbd61f,8/8CI, независимый итоговый PASS.
Новая ветка `codex/sprint-33-v5-cli-upgrade` проверяет отдельную синтетическую
v5 базу, файловый секрет, создание v6 без superuser, сохранность полного
старого проецируемого снимка и независимый учёт. b70e7d6 прошёл10/10CI:
10 новых проверок,60 команд,9 HTTP-наблюдений; ZIP сверён с GitHub.
Выбранные синтетические записи позволяют повторный расчёт без PostgreSQL.
Публикация выбранных данных и контролёр13 подмен требуют собственного CI.
[Критерии и ограничения](SPRINT_33_REPORT.md).
Приватная точка продолжения `.local/sprint21/root/sprint33/RESUME.md`.
Окно по-прежнему заканчивается25.10.2026 01:34:03UTC; не продлевать.
Локальные PG/app остановлены,3131 не трогать. P4 требует реальных наблюдений.

## Sprint32: офлайн-команда через systemd credential

Текущее окно заканчивается25.10.2026 01:34:03UTC; не продлевать при смене даты.
PR44 принят: exactab4095f, независимый PASS и6/6CI, main426a2e7.
Ветка `codex/sprint-32-offline-migration` начинается от этого main.
Подготовлен отдельный CI-only сценарий повторной миграции v6 и атомарного
отказа при намеренно повреждённом checksum на собственной fixture.
Временные oneshot units используют LoadCredential; журналы и наблюдения
отделены от неизменённого строгого сценария Sprint31. d772662 прошёл8/8CI,
7 новых проверок/50 команд/10 HTTP-наблюдений; ZIP сверен с GitHub.
Ранее отказал сам стенд на текстовом LoadCredential=[unprintable]; исправление
читает типизированный D-Bus и связывает причину отказа с реальным PID/unit.
Публикация выбранных данных и контролёр14 подмен требуют собственного CI.
[Критерии и ограничения](SPRINT_32_REPORT.md).

Приватная точка продолжения: `.local/sprint21/root/sprint32/RESUME.md`.
Локальные PostgreSQL/app остановлены, нативные проверки выполняются только
в LinuxCI. Сервис пользователя3131 не трогать. P4 требует реальных журналов
и наблюдений; целевой сервер/домен также пока не предоставлены.

## Sprint31: службы Linux и репетиция обслуживания

Окно: 24.10.2026 17:34:03UTC — 25.10.2026 01:34:03UTC
(06:34:03 Asia/Qyzylorda). Не продлевать при смене даты.
PR38–43 приняты. PR43 head196b40d прошёл независимую приёмку и четыре CI,
включён в main711d4cb. [Результаты Sprint30](SPRINT_30_REPORT.md).

Ветка `codex/sprint-31-linux-service`, [PR44](https://github.com/erkevibe/process-intelligence-rs/pull/44).
Первый systemd-прогон56d2b52 прошёл на новой Ubuntu24.04:13 сценариев,
98 команд,37 запросов. Скачанный протокол проверен по SHA GitHub.
Расширение1cd9d93 до стандартных80/443, восстановления в новую базу,
смены синтетического пароля роли и сертификата прошло19 проверок на одной VM.
В другом workflow дважды истёк30s создания home Caddy; исправление34fe598
создаёт пользователя без home-copy и каталоги явно. Предел не увеличен.
Все шесть CI34fe598 прошли, скачанный протокол19/136/57 сверён с GitHub.
Сохранены выбранные136 команд/57 запросов; контролёр проверяет их
согласованность и десять семантических отказов, включая запуск из архива.
Windows public01 CLOSED: два профильных теста, Clippy и сборка прошли.
Для финального head требуется CI и независимая приёмка перед ready/merge44;
состояние интеграции и актуальные проверки находятся в PR.
[Сценарий и ограничения](SPRINT_31_REPORT.md).

Авторитетная приватная точка продолжения:
`.local/sprint21/root/sprint31/checkpoint.json`, RESUME.md рядом.
Собственные PostgreSQL55449 и app3147 штатно остановлены; PID удалён
самим PostgreSQL. Пользовательский сервис3131 не трогать.
Production-хост, публичные DNS/CA, перезагрузка VM, HA/SLA не заявлены.
P4 выбирается по реальным журналам и замерам; ожидать данных пользователя.

## История прошлого окна

Обновлено 24.10.2026 около16:11UTC. Активная ветка `codex/sprint-28-discovery-jobs`.
Интервал пользователя09:14:49–17:14:49UTC (22:14:49 Asia/Qyzylorda); цель активна.
Продолжать до границы, итог не отправлять заранее.

## Последняя контрольная точка P3, около16:54UTC

PR42 draft, sourcehead4bc8cf048c2f11ca73f62ec69057e0065d8762eb; новыйcommitниже
добавляетпубличнуюevidence/APIchecker/report, затемобязательны2CIточногоhead.
API05/proof.json CLOSED S29_API_CONTRACT_NATIVE_CLOSED:28cases33requests,
8captures16streams97pins;3backupJSONcorrectdigest/expectedresourcesиbyteidentical;
seedqualityreportSHAidenticalafternewPID/creationtime. PGштатноостановлен.
IndependentreviewPASS receipt sprint29-review/final-local-review01.json SHA
 dc7722589c20ce899ada096e720e541b81993b6ad2bb443c03e36970a9afe754.
Public packageevidence/sprint29/api-contract (5files+manifest), portablechecker
verify-api-evidence.py иfrozenexpectedcases/33method-path-status tuples.
TLS/HA/SLA/load/killmidcompute/fullP3не заявляются. Документы API_SUPPORT_CONTRACT,
SPRINT_29_REPORT. Осталосьоколо20миндо17:14:49UTC:CI/reviewточногоfinalhead,
mergeonlygreen,обновитьhandoff;user3131нетронут.

Стандартныйcargo clean -p послеpreserve/hash снял1320files2.7GiB. Старыйowned
root/targetdebugapp/test pathsудаленыкакbuildoutputs; проверенныеapp/test08
сохранены `.local/sprint21/root/sprint29/preserved-build08` receiptSHAвалиден.
API05запущенсpreservedapp.exe темжесамымimageSHA. Это помоглозакрытьguards
безизменениялимитов. Не пересобиратьбезнуждыдо8hdeadline.
## Текущая точка: P3, около16:36UTC

PR41 mergedmain4aea8a019fa0c028dc4e1bb509d8abfe4fc357e4. Finalhead63052a70,
обеCI40110326794/job120920505592 и40110321326/job120920490918 PASS.
P1+P2 завершенывзаявленныхграницах. Тег/releaseне создан; user3131не изменён.
Branchcodex/sprint-29-api-contract основана наmain4aea.
P3новыеfiles:API_SUPPORT_CONTRACT.md,tools/sprint29/api-contract-probe.py,
run-api-contract-ci.sh иCIstep. ПолитиканаблюдаемогоAPI,неSLA/TLS/HA.

Nativeapi01testошибочнопринялdowngradedViewerзаstranger;послеошибкиштатноостановлен.
Исправленреальныйungrantedviewerbeforegrant;backup200/schema/digest/expectedresources
проверяютсяпередbytecompare,повторпослеviewerrefusals. Read-onlyreviewподтвердилаfix.
api02/api03/api04preflightresource_sample_timeout,PGне запускался,этоНЕPASS.
Длясниженияfilecount1029сгенерированныхcounterfactualcopies сохраненыZIPсfullentryhash
verification,удаленытолькодублипоодномуLiteralPath,безrecursiveудалений. Nativeproofs/
proof.json/sourcebundleсохранены. ZIPы:public-counterfactuals04/preserved-cases.zip,
public-native05/counterfactuals/preserved-cases.zip. Guardlimitsunchanged.

CIrunnerP3 теперьреальноstop/waitseedPID→новыйPID→health→probe,показываетrestartJSON.
ПодготовитьdraftPR42счестнымnativeguardlimitations,дождатьсяреальныхLinuxCI,
независимаяreviewsource+closure/CI,сливатьтолькозелёныйточныйhead.
До17:14:49UTCосталосьоколо38мин;неотправлятьfinalраньше.
Ниодинguardpreflightне обходить/неослаблять. PGсейчасcleanstopped.
## Принято

PR38 независимо проверен, исправлен и слит (main4ac5d20f).
P1 сохраняемые оценки/постоянные задания0.9.0: PR39 merged27598a3d,
обеCI40089482950/40089479376 PASS,195tests плюснастоящиеPG/browser/restart.
Документы QUALITY_JOBS_CONTRACT.md, SPRINT_26_REPORT.md, evidence/sprint26.

P2 эксперимент: PR40 merged2ded9b795cda5a80943cfcbbfd4c597fd350afb6,
head4335fd8, обеCI40102008688/40102005232 PASS.205tests, portable234checks.
Публичный811files bundle evidence/sprint27/miner-comparison, SPRINT_27_MINER_REPORT.
Выбран bounded structured_variants_v1. Это эвристика, не полныйIM/неSplitпорт.
РеальныйIM имеет nondeterminism; PythonengineCPU/RAM unknown, неранжировать.

## Активный PR41, продукт0.10.0

https://github.com/erkevibe/process-intelligence-rs/pull/41 — draft, attached.
Producthead71247f323ea4a303a19bef20b4ebfe5151bacf1f, обеCI
40107079865/job120910885168 и40107076673/job120910876155 PASS.
210all-targettests,0fail,29ignored52groups; отдельно5PGscenariosPASS.
Публикация/численныйrestore/CLI/identity/cancel/revoke/stale/historicalretry/
8retained/common2slots1CPU/schema5offlinev4→5 реализованы.

Windows verify08/proof.json CLOSED:64libpass17ignored,compatibility,Clippyalltargets,app.
92buildpins =90Rust+Cargo.toml+Cargo.lock. Core02 другойнабор91pins =90Rust+HTTPscript.
Windows core02/proof.json CLOSED S28_DISCOVERY_CORE_HTTP_COMPLETE_PENDING_INDEPENDENT:
17captures34streams, PGcore+v5migration,old0.9no-writefullSQL,old0.9qualityCLIreportPASS,
read-onlycapacityv5PASS,HTTP32responsesPASS. App3147/PG55449штатноостановлены.
Nativeauditpolicybugвcore01найден/исправлен712; failure/cleanstopсохранены.
verify04/05 остановлены resource_sample_timeout воalltargetcompile,07postscanfailed,
неPASS. verify08cachedcommandsclosed,guardsнеослаблены.

ActualCUA: job30/model32 отlog19 →B3log29 quality33 →downloadmodel32.bpmn→
browseruploadmodel35→quality36. Fullmetrics downloadableexportsidentical:
fitness1,precision5/8,simplicity1. Trainingprecision9/10. Importtraining_unknownhonest.
Browserreload/SSE/form/controlselection проверены. CUA durableTab(IAB2/tab1)сохранён
markHandoff; не закрыватьпоследнюювкладку (прежниеappcrashesрядомсclose,причинанедоказана).
Browserprivate `.local/sprint21/root/sprint28/core02` содержитreports/screenshots/finalAX.
Изображения фактическиJPEG, privateextension.png; publicextensionsисправлены.jpgбезизменениябайтов.

IndependentlocalPASS receipt `.local/sprint21/root/sprint28-review/final-local-review01.json`
SHAbaeaa90930bb499c5c5c6559dd65248c7ce6d9809d76ac4ea7604347f5d64914.
Clarificationall92buildpins receipt02 SHA429d13f049f6979e8b20017406bb8af520b0133a737abdefab166966d312bffa.
01не заменять02:02проуточнениеpincoverage,01полнаяприёмка.
Физическийkillпосредиdiscoverycompute не заявлять (проверенреальныйDBreopen).

## Публичнаяпоставка, незавершённое

`evidence/sprint28/durable-discovery`selectedsyntheticpackage +manifest,credentialsнепубликовать.
Native/buildproofsprojected:args/env/absolutepaths/SQLcontentsопущены.
Новыеtools/sprint28/audit-discovery-evidence.py +23counterfactuals.
Первыйauditor01законноотказалJPEGпод.png,02buildcount91vs92.
Auditor03 отказал из-за неверной замены полного review01 уточняющимreview02.
Исправлено: package содержит оба отдельных projectedreceipt. Финальный
public-native05/proof.json CLOSED S28_PUBLIC_AUDIT_AND_NUMERIC_REPLAY_CLOSED:
20files170001bytes,26coherentcounterfactualrefusals,3actualRustnumericreplayPASS.
Publiccheckerfulltypedmetrics/limits,XMLnode/flowbindingиunsupportedcondition/events/
attrsrejection. NumericCLIповторил2browserdownloads+derivedtrainingadapter.
DirectfastCLI01failedjob_assignrace; sealedS22suspendedpublic-native05закрылвсе6captures.
НиfailedattemptнинезавершённыйcaptureневыданзаPASS.

Independentpublicfinalreview02 PASS SHA c2d548b58dd24d1ab31047729b5a5729c753054c838d6eb27ae65d2cc39a0558:
6captures12streams116configpins,26controls3Rustnumericreplays,package/sourceunchanged.
Publicselectedreceipt evidence/sprint28/public-final-review.json;verification.json.
Contract переименован вdocs/DISCOVERY_JOBS_CONTRACT.md. Docsобновлены.
Нужно finalpackagingcommit/push,2CIокончательногокоммита,ready/mergeguardexpectedhead,
затемP3APIподдержка/операционныеграницы. Productsrc/Cargoне менялисьпосле712.
Guardlimitsroot10GiB–512MiB,total14GiB–512MiB,free>=8GiB,sample25s,неослаблять.
Не запускатьодновременнодванативныхparent/ресурсскана. Nativehelpersвsprint26/sprint27.
User3131не трогать;PG owned `.local/sprint21/root/pgdata11`55449,fixture3147.
Не удалятьpostmaster.pid/WAL. GitHTTPSчерез`-c http.sslBackend=openssl`работает,
SChannelfetchраньшезависал. origin/main2dedобновлён,branchffнанего.

ПриготовленныеSPRINT_28_REPORT.md/DATABASE_RECOVERY.md/READMEобновлены,ещёнезакоммичены.
PlanP3:Linux/TLSоперационныйдопуск,APIподдержка,projectquota(defaultoff/точнаяметрика/
резервterminalrecords/oldbinaryrefusal);необъявлятьэтиэтапызакрытыми.
