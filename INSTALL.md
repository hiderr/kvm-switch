# KVM Switch — быстрая установка

Поставить на **оба** Mac.

## Если используешь Claude Code (рекомендую)

1. Скопируй папку `claude-skill/kvm-switch/` в `~/.claude/skills/` (или в `.claude/skills/`
   рядом с проектом).
2. В Claude Code скажи: «поставь kvm switch» — сработает скилл и проведёт установку.

## Вручную

```sh
# из этой папки
./build.sh                 # нужен Xcode CLT: xcode-select --install
open "KVM Switch.app"
```

Дай права (System Settings → Privacy & Security): **Accessibility** + **Input Monitoring**,
и разреши **локальную сеть** при первом запуске.

Дальше: иконка в меню-баре → «Второй Mac» → выбери другой Mac. Хоткей ⌃⌥⌘S.

Подробности — в `README.md`.
