# Рабочее состояние ProcessMining

Обновлено 24.10.2026 около14:04UTC. Ветка codex/sprint-27-miner-experiment.
Интервал пользователя09:14:49–17:14:49UTC (22:14:49 Asia/Qyzylorda), цель активна.

## Принятая основа

PR38 независимо проверен/исправлен, main4ac5d20f. P1 завершён PR39:
main27598a3d1d14a7f14a2ef3a9225a5abcb13220b7, finalhead7a268b85,
обеCI40089482950/40089479376 PASS;195тестов, PG/migration/oldbinary/restore/
HTTP/browser/restart/cancel. Версия0.9.0 вmain, taggedrelease не создан.
КонтрактQUALITY_JOBS_CONTRACT.md, отчётSPRINT_26_REPORT.md, публичныеevidence26.

## P2: проверенный эксперимент, интеграции продукта ещё нет

Корпуса до новых соответствующих запусков: original A00e0301 (e7522e6),
validation891b1f43 (94824c6), structured A6db9120 (abb244e до реализации).
Rust4PM0.6.2 имеет Alpha+++; наличие RustInductive/Split не предполагается.
Реальный PythonPM4Py2.7.17 IM и настоящий JavaSplitMiner проверены отдельно.
Javaclass E8535A6B...21AD, upstreamsourcebbf24dfd...

- rust02:28native, audits01: complete graph/input/repeat,20PM4Py groups.
- alpha-original01/validation01:28+28native, alpha-audit-original03/validation01:
  по11численныхgroups; default/repair не решили циклы, часть явных отказов.
- java01:14native, projection02+java-scores02, java-audit02:22groups иoriginalXML
  language. Контрольparallelfit0.75,shortloopfit2/3;standardloopunsupported.
- inductive02:28native, inductive-scores01:24оценки; inductive-audit03:
  28rows/52groups/controls20, properPN/XML/projection/roundtrip languages.
  **ДетерминизмFAIL** two_parallel_chains: разные деревья и языки, controlprecision
  7/12 против2/3, simplicity6/7 против23/25. Auditorcompleted не означаетдопускIM.
- Собственный bounded structured_variants_v1: compile04:4behavioraltests,
  Clippy иreleasePASS. Staticindependentreviewисправилempty-case mismatch.
  sv-original02,sv-validation01,sv-structured01:по14native (короткиеsv-labels,
  registry32не ослаблен). structured-series01 связывает3closedproofs.
  sv-audit02:42rows/36modelled/6no_data,76PM4Pygroups, all36finiteWFsound/
  one_safe, tree→mainmodel/net/XML/reimport complete language, repeatsexact.
  Новыйhelperfrozen-inputs проверяетrawcorpusSHA→exacttypedJSON→XES.
  controls20отверглиbool-as-number,wronghash/count/missingheldout,coherent
  train/controlswap,wrongXML/mainmodel/reimport приtrueproducerbooleans.

Независимые immutable receipts sprint27-review:
structured-source-review01; structured-auditors-source-review01;
structured-numerical-review01; inductive-numerical-review01;
structured-reference-encoding-review01 (проверены все72reference netrawSHA).
Явный выбор: structured_variants_v1 для ограниченной продуктовой интеграции.
Это эвристика, не полныйIM/неSplitMinerпорт, не гарантия произвольногокачества.
На повторах/параллелях fitness1, на неизвестнойcontrolactivity~0.933 иprecision
requires_fitting_log. Третий repeated-labelcaseprecision0.5 не скрывать.

## Текущие действия

Публичныйпроектор tools/sprint27/publish-miner-evidence.py готовит приватный
safe bundle перед копией вevidence/sprint27/miner-comparison. publish04/
public-projection04 closed:810files~4.18MB,168invocationrows,55modeldirs,
fullscoredartifacts/references, sanitisedreviews; rawserver/cookies не включены.
Portable public-audit01 честно нашёл reimport netJSON encoding/hash error.
Исправленwriter вsv-audit02:сохраняет exact rawbytes; прежниеproofsне переписаны.
Далее нужен publicaudit дляprojection04 либоследующей05.

Проверяется граница memorycounter дляPM4Py: venvpython.exe скорееredirector,
5MiB/1MiBprivate цифры не выдавать за engineRAM. Native counter scope — один
retainedimage, не process-tree. Сейчас python-image-scope01 session94242:
venv/directPython PID positivecontrol, cap64MiB. Послеproofуточнитьpublisher
measurementpolicy, исключитьPython RAM изranking; исходныеизмерениясохранить.
РеальныйPythonwalltime учитываетожиданиеchild,CPU/RAMengineпока не установлены.

Продуктовыеsrc/Cargo ещё не менялись. Приватные draftфайлы в
.local/sprint21/root/sprint28-draft/: structured_discovery.rs (скопированный
MITown heuristic+checkpoints),discovery_store.rs (не компилирован,черновик).
Контрактплан DISCOVERY_JOBS_CONTRACT_DRAFT.md. Нельзя выдаватьзаготовыйfeature.
Следом:закрытьbundle/audit→docs/report→fullchecks/PR40→новаяветкаdiscoveryjobs.
Интеграция требуетseparate durableartifact/jobmetadata,shared2slots+1CPU,
atomicmodelpublication/auth/revision/cancel,restart/retry,explicitv5migration,
old0.9refusal,backuprestoreverification иbrowserqualitycontrolroundtrip.
StoredModeloptionalexacttrainingidentity; legacyidentityне выдумывать.
Дляversionbumpне ломать0.9qualitymethod:normalise толькоownCargo version в
lockfingerprint, остальныеkernel/dependencybytesсохранить; нуженoldreportCLItest.

## Среда/ограничения

СобственныйPG55449/app3147 остановлены; user3131не трогать. Не удалятьpid/WAL.
Новыеартефакты .local/sprint21/root/sprint27. PrivateP1runtimeсодержатcookies/
пароли, не публиковать. Baseline0.9 binary сохранён sprint27/baseline-v4.exe,
SHA D0A6F2013FDB2EA77098010AFCB16C24B549D6B6A61F9BB862BB95EEB56DE291.
Resourceguards root≤10GiB−512MiB,total≤14GiB−512MiB,free≥8GiB сохранять.
Не менятьpinnedsources во времяnativephase. NewAlpha/IM/SV processcommit512MiB
проверенOSpositive/negativecalibration64MiB;countercalibration02прошёл32MiB.
Не закрыватьпоследнююIABвкладку:двапредыдущихсбояследовалипослеclose,причинане
доказана. ПривозвратеCUAпослекомпактацииrewriteDocumentation;durableTabоставлен.

Неудачныепопыткисохранены, не засчитывать: resource_sample_timeout(java-scores01,
alpha-audit-original01),labelparseaudit02,tuple/listjava-audit01,UUIDinductive01,
syntaxcompile03,ipc_shap структурный42batchstructured01;split на14×3с темиже
лимитами. IMaudit01exporter'id'+flowUUIDpolicy;IMaudit02realrepeatfailure→03
явноrecordsgatefalse. publish01/02слишкомverbose diagnostics2MiBguard,compact
safe projection03/04; boundsне увеличены. Не менятьстарыеproofs/sourcepins.