#!/bin/bash

# Скрипт восстановления базы данных PostgreSQL на новом сервере

# Функция для вывода сообщений с цветом
function colored_echo() {
    local color=$1
    local message=$2
    case $color in
        "red") echo -e "\033[31m$message\033[0m" ;;
        "green") echo -e "\033[32m$message\033[0m" ;;
        "yellow") echo -e "\033[33m$message\033[0m" ;;
        "blue") echo -e "\033[34m$message\033[0m" ;;
        *) echo "$message" ;;
    esac
}

# Функция для проверки ввода пользователя
function prompt_input() {
    local prompt=$1
    local var_name=$2
    local is_password=$3
    local default_value=$4

    while true; do
        if [ "$is_password" = "y" ]; then
            read -sp "$prompt" user_input
            echo
        else
            if [ -n "$default_value" ]; then
                read -p "$prompt (по умолчанию: $default_value): " user_input
                [ -z "$user_input" ] && user_input="$default_value"
            else
                read -p "$prompt: " user_input
            fi
        fi

        if [ -n "$user_input" ]; then
            eval "$var_name='$user_input'"
            break
        else
            colored_echo "red" "Ошибка: значение не может быть пустым"
        fi
    done
}

# Функция для подтверждения действия
function confirm_action() {
    local message=$1
    colored_echo "blue" "$message (y/n)"
    read -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

# Проверка на root
if [ "$(id -u)" -ne 0 ]; then
    colored_echo "red" "Этот скрипт должен запускаться с правами root"
    exit 1
fi

colored_echo "yellow" "\n=== Скрипт восстановления базы данных PostgreSQL ==="

# Получение параметров от пользователя
colored_echo "blue" "\nВведите параметры для восстановления БД:"

prompt_input "Имя пользователя БД" DB_USER "n" "myuser"
prompt_input "Пароль пользователя БД" DB_PASSWORD "y" "6901"
prompt_input "Имя базы данных" DB_NAME "n" "solobot"
prompt_input "Полный путь к файлу бекапа" BACKUP_FILE "n"
prompt_input "Версия PostgreSQL" PG_VERSION "n" "16"

# Вывод сводки
colored_echo "green" "\n=== Параметры восстановления ==="
colored_echo "yellow" "Пользователь БД: $DB_USER"
colored_echo "yellow" "База данных: $DB_NAME"
colored_echo "yellow" "Файл бекапа: $BACKUP_FILE"
colored_echo "yellow" "Версия PostgreSQL: $PG_VERSION\n"

if ! confirm_action "Продолжить с этими параметрами?"; then
    colored_echo "red" "Восстановление отменено пользователем"
    exit 0
fi

# Установка PostgreSQL
if confirm_action "Установить PostgreSQL $PG_VERSION?"; then
    colored_echo "yellow" "\nОбновление пакетов и установка PostgreSQL..."
    apt update
    apt install -y postgresql postgresql-contrib
fi

# Запуск службы PostgreSQL
colored_echo "yellow" "\nЗапуск PostgreSQL..."
systemctl start postgresql
systemctl enable postgresql

# Проверка статуса
PG_STATUS=$(systemctl is-active postgresql)
if [ "$PG_STATUS" != "active" ]; then
    colored_echo "red" "Ошибка: PostgreSQL не запущен. Статус: $PG_STATUS"
    exit 1
else
    colored_echo "green" "PostgreSQL успешно запущен. Статус: $PG_STATUS"
fi

# Создание пользователя и базы данных
colored_echo "yellow" "\nСоздание пользователя и базы данных..."
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
    colored_echo "yellow" "Пользователь $DB_USER уже существует, обновляем пароль..."
    sudo -u postgres psql -c "ALTER USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"
else
    sudo -u postgres psql -c "CREATE USER $DB_USER WITH NOCREATEDB NOCREATEROLE NOSUPERUSER PASSWORD '$DB_PASSWORD';"
fi

if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
    colored_echo "yellow" "База данных $DB_NAME уже существует"
    if confirm_action "Удалить существующую базу данных $DB_NAME и создать заново?"; then
        sudo -u postgres psql -c "DROP DATABASE $DB_NAME;"
        sudo -u postgres createdb "$DB_NAME" --owner="$DB_USER"
    fi
else
    sudo -u postgres createdb "$DB_NAME" --owner="$DB_USER"
fi

# Изменение метода аутентификации
colored_echo "yellow" "\nНастройка аутентификации..."
PG_HBA_FILE="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"
if [ -f "$PG_HBA_FILE" ]; then
    if grep -q "local   all    all           peer" "$PG_HBA_FILE"; then
        sed -i 's/local   all    all           peer/local   all    all           md5/' "$PG_HBA_FILE"
        colored_echo "green" "Файл $PG_HBA_FILE успешно изменен"
    else
        colored_echo "yellow" "Метод аутентификации уже настроен"
    fi
else
    colored_echo "red" "Ошибка: файл $PG_HBA_FILE не найден"
    exit 1
fi

# Перезагрузка PostgreSQL
colored_echo "yellow" "\nПерезагрузка PostgreSQL..."
systemctl restart postgresql

# Проверка существования файла бекапа
if [ ! -f "$BACKUP_FILE" ]; then
    colored_echo "red" "Ошибка: файл бекапа $BACKUP_FILE не найден"
    exit 1
fi

# Восстановление базы данных из бекапа
colored_echo "yellow" "\nВосстановление базы данных из бекапа..."
if confirm_action "Выполнить восстановление базы $DB_NAME из файла $BACKUP_FILE?"; then
    colored_echo "yellow" "Процесс восстановления может занять некоторое время..."
    
    # Проверяем тип файла (текстовый дамп или бинарный)
    if grep -q "PostgreSQL database dump" "$BACKUP_FILE"; then
        # Текстовый дамп
        colored_echo "yellow" "Обнаружен текстовый дамп SQL, используем psql..."
        sudo -u postgres psql -U "$DB_USER" -d "$DB_NAME" -f "$BACKUP_FILE"
    else
        # Бинарный дамп
        colored_echo "yellow" "Обнаружен бинарный дамп, используем pg_restore..."
        sudo -u postgres pg_restore -U "$DB_USER" -d "$DB_NAME" "$BACKUP_FILE"
    fi

    if [ $? -eq 0 ]; then
        colored_echo "green" "\nБаза данных успешно восстановлена из бекапа $BACKUP_FILE"
    else
        colored_echo "red" "\nОшибка при восстановлении базы данных"
        exit 1
    fi
fi

colored_echo "green" "\n=== Процесс завершен успешно ==="
colored_echo "yellow" "Проверьте подключение к базе данных с параметрами:"
colored_echo "yellow" "Пользователь: $DB_USER"
colored_echo "yellow" "База данных: $DB_NAME"
colored_echo "yellow" "Пароль: $DB_PASSWORD"
