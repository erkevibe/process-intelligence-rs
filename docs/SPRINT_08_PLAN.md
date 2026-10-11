# Sprint08 — шесть часов к закрытию R2–R5

Окно 2026-10-11 03:42–09:42 UTC. Последний кандидат не позднее08:12, финальные90минут оставлены независимой проверке и поставке. Полное закрытие означает все15пунктов [матрицы](SPRINT_08_SCOPE.md), а не успешный выбранный срез. Исходные критерии не сокращаются. Нельзя обоснованно гарантировать весь объём за6часов: fullservice и SplitMiner пока не собраны. Работа продолжается автономно к максимально полному доказанному результату; незакрытые пункты явно остаются OPEN.

## S8-P1: предложение после независимых позиций

Совет фиксирован: Root, PM pm_s7, Customer customer_s6, QA/ProcessLogAuditor qa_process, TD/SkillManager technical_debt. Приглашения всем выданы до предложения; позиции сохранены отдельно. Эмоциональный советник emotional_s7 не получает дополнительный голос. Root FOR точного S8-P1. Остальные голоса только реальные, по SHA этого файла; молчание не FOR.

Риск-аппетит средний для нового изолированного кода, минимальный для пользовательских данных. Черновики облегчённые; один явный интегрированный кандидат, независимые QA и TD для новых долговечных данных. Старые0.1–0.5 приложения, кластеры, настройки и архивы не изменять; тесты только на новых принадлежащих спринту ресурсах. Автор не принимает свой код.

1. Root: операторский XES preview → явное подтверждение → новый журнал. Показать исходные/оставшиеся counts, исходные индексы и причины default/removal, полностью пустой результат и строгие отказы. Обычный строгий импорт остаётся доступен. Превью не пишет рабочий проект; отмена удаляет временный токен.
2. Root: original UTF8 bytes/hash, версия политики, действия, actor/time/operation ID атомарно сохраняются с результатом. Не класть raw/actions в mutable log_state: immutable versioned log_source envelope, старый plain EventLog читается без изменения. Новые envelopes требуют нового decoder; downgrade старым бинарником не обещан. Малые summary в state, корректные weak provenance/cache charges, bounded validation and backup/restore. Source download и audit только с актуальными правами проекта. Никакой автоматической cleanup.
3. Root: global maximum2 pending previews, каждый≤20MiB, TTL5мин; принадлежность user/project, повторная авторизация, явное согласие, запрет пустого результата. Short token reservation без удержания общего mutex на parsing/DB. Повтор подтверждения не создаёт второй результат; uncertain persistence обрабатывается fail-closed с durable operation binding либо явным запретом retry до reconciliation. CPU/payload/upload admission сохраняется. Действия≤200000; HTML показывает максимум200 с явным указанием полного отчёта.
4. Назначенный отдельный разработчик: IANA/DST calendar, pinned dependency/tzdb, fixedoffset по умолчанию без изменения старых данных. Именованная зона optional, UTC interval halfopen, локальные weekdays/holidays; неоднозначные и несуществующие рабочие boundaries отклоняются. Overnight явно не поддерживается. Frozen spring/fall/nonhour/holiday/unknownzone/manualUTC expectations до реализации. Общие Cargo/platform/render изменения только через Root integration.
5. PM: ранняя≤40мин feasibility full original service и genuine SplitMiner. Проверить существующие pinned sources/dependencies, сохранить настоящее ограничение/диагностику. Нет reachable stubs, переписанных методов или surrogate miner credit. При успехе предложить отдельное расширение с remaining QA budget; при отказе оставить full criteria OPEN.
6. Отдельный developer при свободном слоте и успешном operational draft: один настоящий выбранный Rust4PM miner/проверяемый model contract либо выбранные conversions/filters. До кода exact scope/quality definitions/manual corpus. Не заменить SplitMiner на Alpha+++ молча, не засчитать training-fit1 как измеренное general quality. Не включать незавершённый optional поток в кандидат.
7. QA: prospective private ACL/log coverage до дорогих прогонов; самостоятельно проверить preview/confirm/refusal/RBAC/user-project binding/replay/cancel/limits/source hash/backup/restart и действия в новойPG. Кандидат из точного Git source, свой запуск/реальный браузер/значимые негативные кейсы. Проверки weak cache и unchanged heavy record versions при view/calendar edits обязательны.
8. TD: независимый audit provenance/cache/atomicity/forwardcompat/DST и ложной full acceptance. Нет авторства calendar или другого принимаемого кода. Реальные stop flags по доказательству; missing functions отдельно от технического долга.
9. Root: meaningful affected ordinary/PG/browser checks, final CI, публичный PR, новый изолированный Windows runtime/package при приёмке runtime изменений. Независимое полное скачивание/manifest/fresh installation и read-only сохранность старых ресурсов. Релиз после фактических QA/TD и большинства Совета. Финальный отчёт15пунктов содержит PASS/OPEN/FAILED/NOT-IN-RUN и время.

## Приёмка выбранного результата (не подмена15полных критериев)

| ID | Доказательство |
|---|---|
| A01 | Реальный UI preview без записи, объяснённые counts/reasons/source IDs, strict import regression и fixed07corpus |
| A02 | Confirm сохраняет точные исходные bytes/hash/policy/actions/actor с новым result в одном commit; duplicate/cancel/expiry/foreign/viewer/capacity/DB failures не публикуют частичное |
| A03 | Restart/backup/newrestore/source download сохраняют bytes и bindings; tampered provenance отказ; old records decode unchanged; downgrade limitation explicit |
| A04 | Нет raw в small mutablemetadata; unchanged payload versions при view/calendar/filter, charged retention+weak eviction, metadata startup bound |
| A05 | Если IANA включена: exact zone/tzdb/DST contract, frozen hand expectations и независимый replay; old fixedoffset unchanged |
| A06 | Fullservice/SplitMiner реальные feasibility verdicts; optionalmodel/filters/conversions отдельно принят и проверен либо отсутствует в кандидате |
| A07 | Exact candidate независимые QA/TD, actual CI, genuine votes/public source+runtime download/fresh installation; protectedold read-only checks |
| A08 | Full15matrix не понижена: каждый результат привязан к доказательству, незакрытые mandatory пункты остаются OPEN |

Стоп: потеря/обход прав, raw в mutable metadata, hidden strong cacheowner, несвязанный audit, upstream identity gap, подмена oracle/качества, опасная olddata mutation, потеря90мин резерва. После STOP новые функции затронутой области приостановлены до исправления/регрессии/независимых заключений и решения Совета. Полезная незатронутая работа продолжается.
