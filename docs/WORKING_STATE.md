# Рабочее состояние ProcessMining

## Sprint30: финальная приёмка P3 Linux/TLS и квоты

Окно: 24.10.2026 17:34:03UTC — 25.10.2026 01:34:03UTC
(06:34:03 Asia/Qyzylorda). Не продлевать окно при смене даты.
Ветка `codex/sprint-30-project-quota`, [PR43](https://github.com/erkevibe/process-intelligence-rs/pull/43).
Основа main `0841257`; PR38–42 приняты.

Код Rust кандидата 0.11.0/schema6 закреплён за804955d; последующие изменения
сохраняют доказательства, проверяют архив и фиксируют Ubuntu24.04. Результат,
проверки и ограничения: [SPRINT_30_REPORT.md](SPRINT_30_REPORT.md).

Windows core07 CLOSED:22 захвата, квота/CAS/Batch/миграция, независимый пересчёт,
14 workflow-сценариев,8 восстановлений очереди,22 ownerHTTP и физический браузер
на окончательной форме. Последний origin04 завершил конфигурационные тесты,
Clippy и сборку. Прежний verify02 выполнил216 общих тестов; новый LinuxCI
выполняет216 общих и отдельно PostgreSQL-проверки(33 исключены из общего запуска).

LinuxCI5719788 прошёл TLS27, семь неверных origin, восстановление очереди и
полный PostgreSQL dump/restore с квотой0 и численной проверкой отчёта.
Отдельное задание проверило скачанный release-артефакт его собственным бинарником.
Сохранены выбранные наблюдения: `evidence/sprint30/project-quota`, `quota-browser`,
`linux-ci`. Публичных паролей рабочих установок, сессий и дампов здесь нет.

Финальные данные и новый контролёр(10 rehash-искажений+2 numeric overflow)
должны пройти CI точного head и независимую проверку перед ready/merge43.
Не объявлять прежний зелёный коммит проверкой нового head. Реальный systemd
runtime, production-домен/DNS/ACME, HA/SLA/RPO/RTO не заявлять.

После принятия43 продолжить P3 отдельным инкрементом: запуск поставляемого unit
systemd в изолированном LinuxCI из скачанного артефакта, LoadCredential,
перезапуск, сохранность и штатная остановка.

Авторитетная приватная точка продолжения:
`.local/sprint21/root/sprint30/checkpoint.json`, RESUME.md рядом.
Собственные PostgreSQL55449 и app3147 штатно остановлены послеcore07; PID удалён
самим PostgreSQL. Пользовательский сервис3131 не трогать. Старые прототипныеv6
fixtureDB имеют иной unreleased checksum; для проверок использовать свежие базы.

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
