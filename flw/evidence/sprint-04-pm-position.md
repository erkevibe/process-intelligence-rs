# Sprint04 — независимая предварительная PM-позиция

Существующее место /root/pm_final, отдельное от Customer/QA/TD. Invitation до immutable proposal. Планового/финального голоса пока нет. Восемь часов14:57:49–22:57:49UTC, последний90min с21:27:49UTC только repairs/QA/delivery. Read accepted ROADMAP, prior TD final/source debt и DATABASE_RECOVERY; первый grouped tool output truncated, ключевые границы уже отдельно читались в предыдущем спринте. Здесь no runtime/data changes. Все рабочие R1/0.2/0.3 пользовательские установки сохраняются.

## Результат и границы

Главный результат — новый формат хранения убирает зависимость изменения маленькой модели/параметра от размера всего проекта. Это операционный вертикальный шаг, не новые miners/BPMN/auth функции. Только «переложить JSON проекта по нескольким таблицам», продолжая serialize всех logs/models на каждый save или typed-load всё в short startup transaction, не закрывает SCALE01. Нужны отдельные durable records и ограниченный affected-record write/read путь, с ясной границей остающегося cache/RSS поведения.

Предложение achievable scope: version2 storage records для logs/models, компактные project/job/view metadata с прежними ресурсными IDs и revisions. Scope primary keys обязательно project+resource: восстановленные проекты могут содержать одинаковые source IDs. Не менять source normalization/order/lifecycle/analysis/model contracts, memberships/session TTL и closed BPMN subset. COUNT8/current per-record safety caps сохранять явно; новый aggregate limit или увеличение count только если отдельно принято и проверено. Горизонтальное масштабирование/64worstprojects не обещать.

## Предлагаемые обязательные критерии

| ID | Пользовательский результат и значимое доказательство |
|---|---|
| PM04-01 Format identity | Immutable schema v1 checksum сохранён; отдельная v2 version/checksum/schema contract. Fresh, recognized0.3 migration, repeatedstartup и future/corrupt/checksum/unknownstate negatives ясны; old0.3 binary наnewstore не называется downgrade |
| PM04-02 Real first adoption | Verified isolated DB backup/restore actual accepted0.3 data → actual oldB38 session/fullbaseline → actualnewEXE firstadoption sameDB. Полные source/analysis/IDs/revisions/policies/views/models/XML/users/memberships/sessions/jobs и два одинаковых имени не изменяются кроме заранее заявленного interrupted recovery |
| PM04-03 Atomic interruption | Singleton до DDL/миграции; meaningful actual ownkill after staged/transformed resources before publication → oldcomplete либо newcomplete, не смешанный проект/ledger. Reopen safely continues/rollsback без duplicate IDs/переписывания исходной копии; repeatedstartup idem; concurrentstartup boundeddenied |
| PM04-04 Localized mutations | Modelsave/view/filter/calendar/import/jobterminal изменяют только объявленные affectedrecords и их smallmetadata; неизменяемые unrelatedlog/model rows fullhash+revision сохраняются. Проверить actualSQL/write identities наfixedlargecorpus; source-only «нет clone» недостаточно |
| PM04-05 Durable cross-record contracts | Completed result+terminaljob atomic, cancel/failure persistedbeforeGET/watch, correctFailed/null при отказе. Controlledwrite/connection/crash не создаёт orphan/partialmanifest; queued/running interrupted recovery/idempotentrestart preserved |
| PM04-06 Isolation and exports | Viewer/foreignknownIDs во всех normalized routes serverdenied; staleCASconflict сохраняет completeoldmodel. Export/backup/restore shape/canonicalsource/models/policies/IDs прежний; newproject scope не конфликтует сsourceIDs |
| PM04-07 Large unchanged proof | SAME preserved cumulative0.3 corpus не уменьшается/reset. Миграция/открытие/изменение smallmodel/параметра/добавление того же100k input и terminal/restart проверяются; новые declaredlimits отображаются отдельно, не masquerade as ускорение |
| PM04-08 Time/RSS measurements | Frozen identicalfixture hashes, hardware/runtime/profile/settings, baselineoldB38 иnewEXE; измерять отдельно migrationfirststartup/repeatedstartup/modelwrite/filter/import и process working-set/peak samplemethod. Минимум3 meaningful runs где бюджет позволяет, median+range; cold/warm labelled. Нет claimspercent/speedup изнесопоставимых runs; scopeappRSS ≠ PG/allmachine RSS |
| PM04-09 Fault/deadlines | Существующие connect5/statement5/lock2/transaction10/response15 не увеличивать радиPASS. Multi-phase migration должна честно определить transaction units/deadline policy, failclosed ambiguouscommit/noautomutationretry; actuallock/termination before/aftercommit durableproof |
| PM04-10 Delivery | Correctedfrozen source/EXE/ZIP tests+separaterealPG+nativePS5freshpublicStart+browser upgrade/restart/provenance; independentQA/TD и newexactCouncil. Publicanonymous wholeZIPhashsize/postlivebeforeCOMPLETE; old runtime unchanged installations maintained |

Finalproposal должен назначить fixed literal pass thresholds дляperformance доexecution либо заранее назвать measurements-only: численные acceptance не выдумывать после результатов. Предлагаю hardmechanism gate PM04-04 (малыйsave не пишет/не serializes unrelatedbiglogs) и публикуемые measurementsPM04-08, без arbitrary2xspeed promise. Если normalized startup пока eagerloads всеcases, так и назвать и не объявлять весьSCALE01closed; отдельный измеренный restbudget и lazyloading remainder.

## Миграция, зависимости и риск

Risk medium feature/low userdata. Большой oldJSON decode/validation нельзя держать внутри короткой SQLtransaction во время CPUwork. Варианты: durable recognized migration staging/checkpoints подexclusivelease с intact oldsource и atomicformatpublication, или bounded realtransaction при доказанном samecorpus fit. Выбор Root должен защищаться конкретным failurestate contract beforecoding; PM не диктует непроверенную многофазную архитектуру. Metadata/version marker нельзя опубликовать до полного проверенного набораresource records. Partial stagedrows читаются только migrationpath, не appclients. Прежняя DB сохраняется отдельно дляrollback; не запускать oldbinary наupgradedDB и не удалять oldsource радиbenchmarks.

Owners: Root storage/migration/localizedwrite interfaces; QA independentfixtures/oldnewactualfault/browser/native/profile measurements; TD separate invariants/estimator/debt review; PM criteria/evidence/measurement interpretation; Customer восстановление/понятныеlimits. Root implementation→actuallargeadoption/faults→freeze/package/QA критическийпуть. PM/Customer source-position не заменяют QA.

Достижимый порядок: ранняяфиксация format/transaction/measurementcontract, localizedrecord prototype, sameoldDBadoption и fault gates, measurements/регрессии, protectedfinal90min. За времяспринта feature expansion исключить. Ifmigration preservesdata ноlocalizedwriteнеработает илиnometrics, итогpartial иSCALE01неclosed; нельзяпереименовать acceptance наrelease.

STOP: liveinstallation target, acknowledgeddataloss/partialpublication, knownIDleak, terminalbeforecommit, reset/shrink mandatorylargecorpus, falseperformance/oldvotetransfer. Безimmutableexactproposal голосотсутствует; никакого sourceedit здесь.
