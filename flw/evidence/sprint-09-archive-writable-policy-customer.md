# Customer — fresh archive writable-replacement policy vote

Vote: **FOR** the exact refinement described in Root invitation; UTC 2026-10-11T09:55:09.0860362Z.

Предложенная политика: перед архивированием инициирующим owner его current проекта должен существовать другой active проект, где этот owner имеет writable role. Для его затронутых sessions выбирается writable replacement. Если доступны только Viewer проекты, отказ до data/audit mutation с объяснением создать writable проект до архивирования. Остальные affected viewers могут перейти в доступный им Viewer проект. Существующие current-writer security gates сохраняются.

Основание: описанный TD реальный lockout owner→Viewer лишает пользователя restore/create/delete. С точки зрения пользователя успешное обратимое архивирование не должно закрывать его единственный путь восстановления. Ранний отказ с конкретной инструкцией понятнее успешного перенаправления в тупик. Не предлагать повышать Viewer права, скрытно создавать проект или выбирать чужой replacement.

Это самостоятельное новое согласие с уточнением, не runtime PASS. Root должен сохранить exact refinement/decision и независимую QA проверку: owner+onlyViewer отказ/full state+audit unchanged, owner+Editor либо Owner replacement успех/restore доступен, несколько initiator sessions writable rebind, ordinary other Viewer доступ остаётся ограниченным, stale rights/revision/concurrent archive отказ. Текущий frozen plan/spec bytes не редактировать; уточнение отдельным additive artifact. Если invited policy означает также архивирование noncurrent проекта, новая writable предпосылка к нему автоматически не распространяется: покрытый дефект относится к потере current writable контекста. Protected installations untouched.

Hash invitation не предоставлен, поэтому не выдумываю file SHA точного предложения: предмет голосования полностью воспроизведён выше. Требуется запись председателем exact decision до реализации изменённой политики.
