# Рабочее состояние ProcessMining

Обновлено 24.10.2026 около16:11UTC. Активная ветка `codex/sprint-28-discovery-jobs`.
Интервал пользователя09:14:49–17:14:49UTC (22:14:49 Asia/Qyzylorda); цель активна.
Продолжать до границы, итог не отправлять заранее.

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