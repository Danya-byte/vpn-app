// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get appTitle => 'VPN App';

  @override
  String get navHome => 'Главная';

  @override
  String get navActivity => 'Активность';

  @override
  String get navSettings => 'Настройки';

  @override
  String get tabConnections => 'Соединения';

  @override
  String get tabLogs => 'Логи';

  @override
  String get coreSubtitle => 'sing-box • Windows';

  @override
  String get statusConnected => 'Подключено';

  @override
  String get statusChecking => 'Проверяю соединение…';

  @override
  String get statusConnecting => 'Подключение…';

  @override
  String get statusDisconnecting => 'Отключение…';

  @override
  String get statusDisconnected => 'Отключено';

  @override
  String get statusError => 'Ошибка';

  @override
  String get profiles => 'Профили';

  @override
  String get profilesEmpty => 'Пусто. Вставь ссылку или подписку ниже.';

  @override
  String get noProfile => 'Нет профиля';

  @override
  String get tapToAdd => 'нажми, чтобы добавить';

  @override
  String get core => 'Ядро';

  @override
  String get coreNotRunning => 'sing-box (не запущено)';

  @override
  String get localProxy => 'Локальный прокси';

  @override
  String get upload => 'Отдача';

  @override
  String get download => 'Загрузка';

  @override
  String coreLogsTitle(int count) {
    return 'Логи ядра ($count)';
  }

  @override
  String get copy => 'Копировать';

  @override
  String get copied => 'Логи скопированы';

  @override
  String get empty => 'Пусто';

  @override
  String get btnLinkList => 'Ссылка / список';

  @override
  String get btnSubscriptionUrl => 'Подписка URL';

  @override
  String get btnFromClipboard => 'Из буфера';

  @override
  String get btnFromFile => 'Из файла';

  @override
  String get btnScanScreenQr => 'Сканировать QR с экрана';

  @override
  String get btnExport => 'Экспорт профилей…';

  @override
  String get exportDone => 'Профили экспортированы';

  @override
  String get addProfile => 'Добавить профиль';

  @override
  String get dlgImportTitle => 'Ссылка или подписка';

  @override
  String get dlgImportHint =>
      'vless://…  (несколько строк или base64 — тоже ок)';

  @override
  String get cancel => 'Отмена';

  @override
  String get importAction => 'Импорт';

  @override
  String get dlgUrlTitle => 'Подписка по URL';

  @override
  String get dlgUrlHint => 'https://…';

  @override
  String get loadAction => 'Загрузить';

  @override
  String msgAddedNodes(int count) {
    return 'Добавлено нод: $count';
  }

  @override
  String switchedTo(String member) {
    return 'Переключено на $member';
  }

  @override
  String get msgNotRecognized => 'Не распознал ни одной ноды';

  @override
  String get msgQrNotFound => 'QR-код в изображении не найден';

  @override
  String get msgSubscriptionEmpty => 'Подписка пуста';

  @override
  String get msgClipboardEmpty => 'В буфере нет нод';

  @override
  String get msgAlreadyImported => 'Уже импортирован — переподключаюсь';

  @override
  String msgLoadError(String error) {
    return 'Ошибка загрузки: $error';
  }

  @override
  String get modeGlobal => 'Global';

  @override
  String get modeSmart => 'Smart';

  @override
  String get modeGlobalDesc => 'Весь трафик через прокси';

  @override
  String get modeSmartDesc => 'RU и локалка — напрямую, остальное через прокси';

  @override
  String get language => 'Язык';

  @override
  String get languageSystem => 'Системный';

  @override
  String get about => 'О приложении';

  @override
  String get version => 'Версия';

  @override
  String get developer => 'Разработчик';

  @override
  String get sourceCode => 'Исходный код (GitHub)';

  @override
  String get factsFeed => 'Данные о цензуре';

  @override
  String get factsFeedBuiltIn => 'Встроенные (обновляются при подключении)';

  @override
  String get vpnModeTitle => 'Режим VPN';

  @override
  String get antiDpiTitle => 'Анти-DPI (фрагментация TLS)';

  @override
  String get antiDpiDesc =>
      'Дробит TLS-рукопожатие против DPI по SNI. Чуть медленнее.';

  @override
  String get autoFailoverTitle => 'Авто-фейловер';

  @override
  String get autoFailoverDesc =>
      'urltest по всем узлам: быстрейший рабочий, авто-переключение при блокировке.';

  @override
  String get restartAsAdmin => 'Перезапустить как администратор';

  @override
  String get refreshSubs => 'Обновить подписки';

  @override
  String get subsUpToDate => 'Подписки актуальны';

  @override
  String get createOwnNode => 'Создать свой узел';

  @override
  String get routingMode => 'Маршрутизация';

  @override
  String get vpnModeProxy => 'Прокси';

  @override
  String get vpnModeTun => 'TUN';

  @override
  String get vpnModeProxyDesc =>
      'Через туннель идут только браузеры и прокси-приложения — без прав админа. Остальные приложения и их DNS идут НАПРЯМУЮ (реальный IP виден). Для полной защиты используйте режим TUN.';

  @override
  String get vpnModeTunDesc =>
      'Весь трафик системы через VPN-адаптер (все приложения, UDP). Нужны права администратора.';

  @override
  String get serverGenDesc =>
      'Свой VPS → чистый IP не в списках РКН + Reality-маскировка под реальный сайт = оператор-пруф.';

  @override
  String get serverGenIp => 'IP вашего VPS';

  @override
  String serverGenMasquerade(String sni) {
    return 'Маскировка под $sni';
  }

  @override
  String get generating => 'Генерирую…';

  @override
  String get generate => 'Сгенерировать';

  @override
  String get serverGenStep1 =>
      '1. Скрипт установки (вставь на VPS по SSH под root)';

  @override
  String get serverGenStep2 => '2. Добавить клиентский профиль';

  @override
  String get serverGenAdded =>
      'Профили добавлены (Reality + Hysteria2). Задеплой сервер скриптом и подключайся.';

  @override
  String get noConnections => 'Нет активных соединений';

  @override
  String connectionsActive(int count) {
    return 'активно: $count';
  }

  @override
  String get viewConfig => 'Конфиг sing-box';

  @override
  String get dropToImport => 'Отпустите конфиг, ссылку или QR';

  @override
  String get onboardTitle => 'Добавьте первый сервер';

  @override
  String get onboardBody =>
      'Бросьте QR или файл конфига, вставьте ссылку или откройте файл — затем нажмите подключение.';

  @override
  String get onboardAdd => 'Добавить сервер';

  @override
  String get setupTitle => 'Выберите защиту';

  @override
  String get setupBody =>
      'Как VPN должен защищать этот ПК? Изменить можно в любой момент в настройках.';

  @override
  String get setupTunTitle => 'Полная защита устройства';

  @override
  String get setupTunBody =>
      'Весь трафик всех приложений идёт через туннель — без утечек DNS и IPv6. При подключении запросит права администратора.';

  @override
  String get setupTunBadge => 'Надёжнее всего';

  @override
  String get setupProxyTitle => 'Прокси приложений';

  @override
  String get setupProxyBody =>
      'Проще и не требует прав администратора, но защищены только прокси-совместимые приложения — остальной трафик может идти напрямую.';

  @override
  String get setupProxyBadge => 'Просто';

  @override
  String get delete => 'Удалить';

  @override
  String deleteProfileConfirm(String name) {
    return 'Удалить «$name»?';
  }

  @override
  String get measuring => 'измеряю…';

  @override
  String get serverGenInvalidIp => 'Введите корректный IP-адрес';

  @override
  String get serverGenFailed =>
      'Не удалось сгенерировать — проверьте ядро и повторите';

  @override
  String get importFailed =>
      'Импортировано, но туннель не поднялся с этим профилем';

  @override
  String get importNoTraffic =>
      'Подключено, но трафика нет — сервер может быть недоступен';

  @override
  String get importNotConnected =>
      'Импортировано — не подключено. Проверьте в списке.';

  @override
  String get importDiscarded => 'Отклонено и удалено';

  @override
  String get importReviewTitle => 'Импортированный сервер';

  @override
  String get importProtocol => 'Протокол';

  @override
  String get importServer => 'Сервер';

  @override
  String get importConfigProfile => 'конфиг sing-box';

  @override
  String get importExit => 'Маршрут по умолчанию';

  @override
  String get importRoutesDirect =>
      'Этот конфиг пускает ВЕСЬ трафик напрямую — без защиты VPN';

  @override
  String get importConnectAction => 'Подключиться';

  @override
  String get importExternalWarning =>
      'Этот сервер пришёл из внешней ссылки или QR-кода. Враждебный сервер видит и может подменять весь ваш трафик — подключайтесь, только если доверяете источнику.';

  @override
  String get importFetchTitle => 'Скачать список серверов?';

  @override
  String importFetchBody(String host) {
    return '$host получит ваш IP-адрес, и приложение загрузит предоставленный им список серверов. Продолжайте, только если доверяете ссылке.';
  }

  @override
  String get importFetchInsecure =>
      'Это http:// (незашифрованная) ссылка — список серверов могут подменить по пути. Лучше используйте https://.';

  @override
  String get importContinue => 'Продолжить';

  @override
  String get errCoreMissing =>
      'Файл ядра не найден. Переустановите приложение.';

  @override
  String get errTunNeedsAdmin =>
      'Режим TUN требует прав администратора.\nНастройки → Режим VPN → «Перезапустить как администратор».';

  @override
  String errConfigRejected(String detail) {
    return 'Ядро отклонило конфиг:\n$detail';
  }

  @override
  String errWriteFailed(String detail) {
    return 'Не удалось записать конфиг: $detail';
  }

  @override
  String errLaunchFailed(String detail) {
    return 'Не удалось запустить ядро: $detail';
  }

  @override
  String get errNoApi => 'Ядро запустилось, но не ответило на Clash API.';

  @override
  String get errReconnecting =>
      'Соединение прервано — переподключаюсь (трафик заблокирован, без утечки)…';

  @override
  String get errGaveUp =>
      'Не удалось подключиться после нескольких попыток — проверьте профиль или сеть.';

  @override
  String get errKillSwitchFailed =>
      'Kill-switch включён, но firewall-фенс не удалось установить — не подключаюсь без защиты. Запустите приложение от администратора или выключите kill-switch в настройках.';

  @override
  String get errProxyFailed =>
      'Не удалось задать системный прокси — не подключаюсь (приложения пошли бы напрямую, без защиты). Проверьте права на прокси/реестр Windows.';

  @override
  String get errXrayMissing =>
      'Этому профилю нужен мост xray (xray.exe), которого нет в установке. Переустановите приложение или восстановите xray.exe.';

  @override
  String updateAvailable(String version) {
    return 'Доступно обновление: $version';
  }

  @override
  String get serverGenChainToggle => 'Цепочка через реле в РФ (2 VPS)';

  @override
  String get serverGenChainDesc =>
      'Реле на российском облаке (маскируется под настоящий рос. сайт) перенаправляет на зарубежный выход. ТСПУ видит только домашний трафик RU-IP ↔ RU-SNI — оператор-пруф.';

  @override
  String get serverGenRelayIp => 'IP реле-VPS (РФ)';

  @override
  String get serverGenExitIp => 'IP зарубежного VPS-выхода';

  @override
  String get serverGenRelayScript => '1а. Установка реле (на RU VPS)';

  @override
  String get serverGenExitScript => '1б. Установка выхода (на загран. VPS)';

  @override
  String get serverGenChainAdded =>
      'Профиль-цепочка добавлен — подключайся; ТСПУ видит только домашний трафик.';

  @override
  String get diagnostics => 'Проверка';

  @override
  String get diagRun => 'Проверить сеть';

  @override
  String get diagChecking => 'Проверяю…';

  @override
  String get diagControls => 'Контрольные (должны работать в РФ)';

  @override
  String get diagBlocked => 'Заблокировано РКН (VPN должен починить)';

  @override
  String get diagDirect => 'Напрямую';

  @override
  String get diagViaVpn => 'Через VPN';

  @override
  String diagRescued(int count, int total) {
    return 'VPN разблокирует $count из $total заблокированных';
  }

  @override
  String get diagConnectHint =>
      'Подключите VPN, чтобы сравнить колонку «Через VPN».';

  @override
  String get vOk => 'OK';

  @override
  String get vDnsPoisoned => 'DNS подменён';

  @override
  String get vTlsDpi => 'TLS DPI';

  @override
  String get vTcpReset => 'TCP сброс';

  @override
  String get vTimeout => 'Таймаут';

  @override
  String get vDown => 'Недоступен';

  @override
  String get tlsFpTitle => 'TLS-фингерпринт (uTLS)';

  @override
  String get tlsFpDesc =>
      'Маскировка TLS-рукопожатия под этот браузер. «random» — ротация реальных браузеров на каждом соединении.';

  @override
  String get muxTitle => 'Мультиплекс (mux)';

  @override
  String get muxDesc =>
      'Много потоков в одном TLS-соединении — меньше соединений, которые DPI может отследить. Пропускается для Vision/QUIC.';

  @override
  String subDaysLeft(int days) {
    return 'осталось $days дн.';
  }

  @override
  String get subExpired => 'истёк';

  @override
  String get autoAdaptTitle => 'Авто-адаптация к блокировке';

  @override
  String get autoAdaptDesc =>
      'Если ТСПУ начнёт душить живой туннель, приложение само перебирает TLS-фингерпринт / фрагментацию / mux, пока трафик не пойдёт — без ручной возни.';

  @override
  String get errPortInUse =>
      'Локальный порт занят — запущена другая копия приложения (возможно, от администратора). Закройте её и переподключитесь.';

  @override
  String get connectOnLaunchTitle => 'Подключаться при запуске';

  @override
  String get connectOnLaunchDesc =>
      'Если VPN был включён при закрытии приложения, при следующем открытии подключится автоматически.';

  @override
  String get registerLinksTitle =>
      'Открывать ссылки vpn:// и конфиги этим приложением';

  @override
  String get registerLinksDesc =>
      'Зарегистрировать ссылки vpn:// / sing-box:// и добавить приложение в список «Открыть с помощью» для .json — клик по ссылке или конфигу импортирует сюда. Без прав админа.';

  @override
  String get autostartTitle => 'Запуск при старте системы';

  @override
  String get autostartDesc =>
      'Запускать приложение при входе в Windows. Без админа. В режиме TUN туннелю всё равно нужен админ — для запуска без UAC используйте режим прокси.';

  @override
  String get closeToTrayTitle => 'Сворачивать в трей при закрытии';

  @override
  String get closeToTrayDesc =>
      'Закрытие окна прячет его в трей, туннель продолжает работать. Откройте снова по иконке в трее, или ПКМ по иконке → Quit для выхода.';

  @override
  String get errWireguardHandshake =>
      'WireGuard-рукопожатие не завершилось — туннель «подключён», но не передаёт трафик. Сервер недоступен, либо это конфиг AmneziaWG: его обфускация ядром не поддерживается (ядро говорит на обычном WireGuard), а обычный WireGuard в РФ душат. Используйте узел VLESS+Reality или Hysteria2.';

  @override
  String get insecureBadge => 'без проверки серта';

  @override
  String get policies => 'Политики';

  @override
  String get policiesEmpty =>
      'В этом профиле нет переключаемых групп.\nПолитики есть только у конфигов с несколькими узлами (Selector / URLTest).';

  @override
  String get policyAuto => 'авто';

  @override
  String get policyTestAll => 'Проверить все';

  @override
  String get policyAlive => 'Живые узлы (ответили на проверку через туннель)';

  @override
  String get policyTimeout => 'таймаут';

  @override
  String get policiesPreview =>
      'Предпросмотр — подключитесь, чтобы переключать серверы и мерить пинг.';

  @override
  String get speedTestRun => 'Тест';

  @override
  String get speedTestRetry => 'Ещё раз';

  @override
  String get speedTestHint => 'Реальная скорость через туннель';

  @override
  String get speedTestConnect => 'Подключитесь для теста скорости';

  @override
  String get speedTestDownloading => 'Загрузка…';

  @override
  String get speedTestUploading => 'Отдача…';

  @override
  String get killSwitchActive => 'Kill-switch вкл';

  @override
  String get killSwitchUnprotected =>
      'Kill-switch ВКЛ, но защита НЕ установлена';

  @override
  String get proxyModeLeakHint =>
      'Режим прокси — приложения, игнорирующие системный прокси, идут напрямую';

  @override
  String get whitelistModeTitle => 'Режим белого списка';

  @override
  String get whitelistModeBody =>
      'Мобильную сеть свернули до государственного белого списка — открыты только российские сайты, зарубежный выход недоступен. Это не блокировка узла; нужен Wi-Fi или домашний релей.';

  @override
  String get unblockHint =>
      'Kill-switch заблокировал весь трафик после сбоя туннеля.';

  @override
  String get unblockAction => 'Отключить и разблокировать';

  @override
  String get insecureConnectTitle => 'Подключиться без проверки сертификата?';

  @override
  String get insecureConnectBody =>
      'Этот сервер отключает проверку TLS-сертификата — атакующий в сети может прочитать или подменить ваш трафик. Всё равно подключиться?';

  @override
  String get insecureConnectAction => 'Всё равно подключиться';

  @override
  String get splitTunnelTitle => 'Per-app маршрутизация (TUN)';

  @override
  String get splitTunnelDesc =>
      'Маршрут для каждого приложения. НАПРЯМУЮ = мимо VPN — только для тех, кто работает БЕЗ VPN и кому нужен низкий пинг (игра на RU-серверах). ЧЕРЕЗ VPN = закрепить заблокированное приложение (Discord, заблок. игры) на туннеле, чтобы всегда работало. Добавь точное имя .exe.';

  @override
  String get splitDirectLabel => 'Напрямую (мимо VPN)';

  @override
  String get splitVpnLabel => 'Принудительно через VPN';

  @override
  String get splitTunnelHint => 'процесс.exe';

  @override
  String get splitTunnelEmpty => 'Пусто';

  @override
  String get brutalTitle => 'Скорость Hysteria2 (Brutal)';

  @override
  String get brutalDesc =>
      'Укажите реальную скорость соединения, чтобы Hysteria2 держал поток при потерях пакетов. Пусто = авто. Влияет только на серверы Hysteria2.';

  @override
  String get brutalDown => 'Загрузка, Мбит/с';

  @override
  String get brutalUp => 'Отдача, Мбит/с';

  @override
  String get brutalHint => 'авто';

  @override
  String get dnsTitle => 'Свой DNS (DoH)';

  @override
  String get dnsDesc =>
      'DNS-over-HTTPS резолвер для всех запросов. Пусто = по умолчанию (Yandex 77.88.8.8, всегда доступен в РФ). Указывайте сервер, которому доверяете — заблокированный просто сломает разрешение имён.';

  @override
  String get dnsHint => 'напр. 1.1.1.1 или dns.google';

  @override
  String get killSwitchTitle => 'Kill-switch для TUN (экспериментально)';

  @override
  String get killSwitchDesc =>
      'В режиме TUN ставит фаервол-фенс (Windows Filtering Platform): при падении ядра блокирует ВЕСЬ трафик кроме туннеля — без утечки в открытую при реконнекте. Снимается автоматически при выходе из приложения, заблокировать сеть не может. Экспериментально: проверь в бою, прежде чем полагаться.';

  @override
  String get settingsAdvanced => 'Дополнительно';

  @override
  String get settingsAdvancedHint =>
      'Настроено автоматически под РФ — обычно менять ничего не нужно.';

  @override
  String get logLevelTitle => 'Логи';

  @override
  String get logLevelDesc =>
      'Сколько деталей в логе приложения (Активность → Логи). Warn = тихо (только предупреждения/ошибки), Info = каждое соединение, Debug = всё.';
}
