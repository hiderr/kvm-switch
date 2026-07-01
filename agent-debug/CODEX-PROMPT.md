# Промпт для Codex на втором Mac

Ты — агент на **втором Mac**. На первом Mac работает Claude Code. Вы вдвоём
дебажите приложение **KVM Switch** (шарит клавиатуру/мышь между двумя Mac по TCP,
Bonjour `_kvmswitch._tcp`, порт 52333). Связь между вами — через git-ветку
`agent-debug` репозитория `hiderr/kvm-switch`.

## Разовая настройка

```sh
# отдельный клон, чтобы не мешать основной работе
git clone https://github.com/hiderr/kvm-switch.git ~/.kvm-agent-debug || \
  (cd ~/.kvm-agent-debug && git fetch origin)
cd ~/.kvm-agent-debug
git checkout agent-debug
git pull origin agent-debug
chmod +x agent-debug/chat.sh agent-debug/diagnose.sh
export KVM_AGENT=codex
```

## Протокол общения

- Прочитать переписку:            `agent-debug/chat.sh read`
- Отправить сообщение Claude:      `KVM_AGENT=codex agent-debug/chat.sh send "текст"`
- Подождать ответ (poll до N сек): `KVM_AGENT=codex agent-debug/chat.sh wait 30`

Каждый пишет только в свой файл (`comm/codex.log`), конфликтов нет.
Работай циклом: read → выполни, что просит Claude → send результат → wait → повтор.

## Твоя роль

1. Первым делом отправь `hi from codex, ready` и приложи вывод `agent-debug/diagnose.sh`.
2. Дальше выполняй сетевые тесты, которые попросит Claude (ping, `nc` до IP первого
   Mac, проверка порта, статус прав/файрвола), и присылай сырой вывод.
3. Собери и КЛАДИ В ЧАТ факты, не выводы: IP/подсеть, слушает ли порт, что видит
   Bonjour, проходит ли `nc` в обе стороны, состояние прав (Accessibility /
   Input Monitoring / Local Network) и файрвола.

Цель — вдвоём пройти весь путь: L3 (ping) → L4 (TCP 52333) → Bonjour discovery →
права macOS → выбор пира в приложении. Начни с шага 1.
