# Sprint09: точное итоговое предложение — доказательства и исходники, выпуск отложен

Председатель Root. Предложение сформировано после действительного приглашения и пяти независимых исходных позиций, до пяти новых голосов. Голос FOR относится только к описанному ниже конечному результату, не к выпуску продукта или закрытию R3.

## Предлагаемое решение

1. Сохранить выполненную реализацию, неизменный кандидат и конечные фактические доказательства для обзора исходников. Опубликовать безопасные документы и evidence в текущей публичной ветке; PR10 оставить draft. Допускаются только последующие изменения evidence/документов/метаданных CI и передачи, без изменения frozen runtime.
2. R3-01, R3-02, R3-04 и DISK01 остаются OPEN. C17 SQL5 — INCONCLUSIVE_NOT_PASS: реальный SELECT завершился успешно, обязательный same-backend57014 не наблюдён. Полная сохранность и другие fault cases не заменяют этот gate. Не переносить C1 PASS, не менять corpus, timeout budgets или ожидания.
3. Не выполнять официальный релиз/тег0.7.1, merge или новую human installation. Не включать непроверенный Apply в принятый выпуск. Сохранить принятую0.6.1 и прежние установки. Локальный Windows ZIP — кандидат для review, не accepted delivery.
4. Признать только конечные наблюдаемые результаты в связанном QA aggregate: audit/lifecycle/retention/import trust, прямое удаление/cache/restart, rollback/failclosed, отдельный unknownACK/manual recovery, настоящее migrated legacy+marker deletion, полный old0.3 C01/C02/C18, refusal guards, F01–F03, known-COMMIT receipt failure4 и реальные LOCK2/TX10. Это scoped evidence, не whole-criterion PASS/enterprise/global exactly-once/physical erasure/eternal tombstones.
5. Завершить передачу публичных исходников/evidence и CI точного audit head в оставшемся восьмичасовом бюджете. Следующее принятие cleanup начинается с независимо проверенного инструмента настоящей SQL5 boundary на полном неизменном наборе и прежних5/2/10 бюджетах; новая попытка требует отдельного prospective scope, не blind retry текущей операции.

## Замороженные привязки

- Runtime source b4edef34b083d1cb7737cf648f1c051eeb94127a, version0.7.1.
- EXE SHA2567FC3812772D64D9A74EEC55413C41C6C189167FFEB279EFCE2613CA7FD6AD195.
- Windows ZIP SHA256EDACC3B836B5660439FFAA684A3D92451512731ADD9AAE89F0703A6E400C975A.
- Frozen build source archive SHA256858EFE55642813631416DE9F5EC1170735AB23B2077A2F552C113E39267AED0A.
- Отчёт docs/SPRINT_09_REPORT.md SHA256771C7FEEE23C4E9FE1628A3B20A5880786D2E403192825AF84264652BE469B15; сохраняется неизменным при голосовании. Позднее actual решение и delivery receipt — отдельные файлы.
- QA aggregate flw/evidence/sprint-09-qa-c2-bounded-aggregate01.json SHA256A4D561E467B3F6C3C5B1C8DDF7136017DDB0A28DD2B135C4A7D8EC9E6B74B490:25полностью связанных входов, C01–C18/F01–F03, все criteria OPEN, ограничения native capture.

## Действительные исходные позиции до предложения

Приглашение sprint-09-final-review-invitation01.json SHA25623278B4CEDE01F831B9CC6A05EE2AB841430A282BA30C87957899EF11581BDBC.

| Роль | Файл в flw/evidence | SHA256 |
|---|---|---|
| Root | sprint-09-root-final-initial-position01.md | CBC1612160F063DDD55CDE71E85AC56684C7909E17BAF618C8E57716EC1C28D8 |
| PM | sprint-09-pm-final-initial-position01.md | 7D6BE1473AC9C71A6E90153EAE81D64B4D8A60EEB07C95BF7B4D35B638BBF34D |
| Customer | sprint-09-customer-final-initial-position01.md | 53B8B7D9950FEAC4EBEF14CE6E4E7C1A08851F5A5527D889F4D94066E12808B6 |
| QA/ProcessLogAuditor | sprint-09-qa-final-initial-position01.md | C6D236F7960542A10034E8D38BCC64D030C883B3E40B37FBF0FD6A2CCB05FE09 |
| TechnicalDebt | sprint-09-td-final-initial-position01.json | 889E5F9D77951CA9CBEB69D0BC7F4B8B1A16FB3C7456CEC3B769F18F85FE12B8 |

Все позиции — позиции, не голоса. Их ранние pending поля сохраняются как исторические точки наблюдения. Поздний QA aggregate подтверждает полный genuine deletion oracle E36B6653 и актуальные полные проверки; его должен прочитать каждый голосующий вместе с точным предложением. Коррекция verifier defaults/empty maps не изменила frozen expected delta и не повторяла mutation.

## Обязательные сохранённые ограничения

Cold intentionally-stopped app/native5-parent final exits UNKNOWN. Precise OS creation текущего L05 proxy отсутствует; native spawn/path/SHA/exit сохранены. Real LOGIN HTTP response artifact отсутствует при доказанном ровно одном persisted session delta. Customer UI видела explanatory trust labels и empty preview/zero audit rows, не live три badges/непустой проект. Archive слово «доступный» требует ясного «для записи»; runtime guard отдельно проверен, guide уже уточнён. Нет total observer RAM bound/TOAST no-read/all-machine/continuous every-descendant attestation. Все failed/refused attempts сохранены. Ранний SQL5 restore locked-file review позднее дополнен успешным полным rehash, не переписан.

Root source download — anonymous200/805fullfiles length+SHA match, не Windows accepted release. Protected comparison —15названных process/image/health identities и3старых ZIP, не проверка всех пользовательских данных. Другие роли ссылаются на эти Root proofs как attributed reports, если не повторяли их независимо.

## Голосование и завершение

Фиксированные пять участников: Root, PM /root/pm_s9, Customer /root/customer_s6, QA+ProcessLogAuditor /root/qa_process, TechnicalDebt /root/technical_debt. Каждый полностью читает предложение, проверяет SHA и связанные точные report/aggregate привязки, затем сохраняет новый фактический FOR/AGAINST с причиной. Председатель считает только эти реальные голоса. Ни silence, ни initial positions, ни старые plan/resume votes не считаются FOR. Финальное решение и factual source/evidence/CI receipt сохраняются отдельно, с неизменным runtime.
Actual proposal UTC: 2026-10-11T14:34:01.3545623Z
