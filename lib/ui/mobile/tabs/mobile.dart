import 'dart:async';
import 'dart:io';
import 'dart:convert';


import 'package:http/http.dart' as http;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:network_proxy/native/app_lifecycle.dart';
import 'package:network_proxy/native/pip.dart';
import 'package:network_proxy/native/vpn.dart';
import 'package:network_proxy/network/bin/configuration.dart';
import 'package:network_proxy/network/bin/server.dart';
import 'package:network_proxy/network/channel.dart';
import 'package:network_proxy/network/handler.dart';
import 'package:network_proxy/network/http/http.dart';
import 'package:network_proxy/network/http/websocket.dart';
import 'package:network_proxy/network/http_client.dart';
import 'package:network_proxy/ui/configuration.dart';
import 'package:network_proxy/ui/content/panel.dart';
import 'package:network_proxy/ui/content/panel.dart';
import 'package:network_proxy/ui/launch/launch.dart';
import 'package:network_proxy/ui/mobile/menu/left_menu.dart';
import 'package:network_proxy/ui/mobile/menu/more_menu.dart';
import 'package:network_proxy/ui/mobile/request/list.dart';
import 'package:network_proxy/ui/mobile/request/mobile_search.dart';
import 'package:network_proxy/ui/mobile/widgets/connect_remote.dart';
import 'package:network_proxy/ui/mobile/widgets/pip.dart';
import 'package:network_proxy/utils/ip.dart';
import 'package:network_proxy/utils/lang.dart';
import 'package:network_proxy/utils/listenable_list.dart';

// import 'package:network_proxy/ui/mobile/setting/mobile_ssl.dart';
// import 'package:network_proxy/ui/mobile/widgets/home.dart';
import 'package:network_proxy/storage/histories.dart';

// import 'package:network_proxy/ui/component/utils.dart';
// import 'package:network_proxy/ui/mobile/menu/setting_menu.dart';
// import 'package:network_proxy/utils/navigator.dart';

import 'package:provider/provider.dart';
import 'package:network_proxy/utils/appInfo.dart';

class MobileHomePage extends StatefulWidget {
  final Configuration configuration;
  final AppConfiguration appConfiguration;
  final ProxyServer proxyServer;
  final ListenableList<HttpRequest> container;

  const MobileHomePage(this.configuration, this.appConfiguration, this.container, {super.key, required this.proxyServer});

  @override
  State<StatefulWidget> createState() {
    return MobileHomeState();
  }
}

class MobileHomeState extends State<MobileHomePage> implements EventListener, LifecycleListener  {
  static final GlobalKey<RequestListState> requestStateKey = GlobalKey<RequestListState>();
  // static final container = ListenableList<HttpRequest>();
  static late ListenableList<HttpRequest> container;


  /// - 远程连接
  final ValueNotifier<RemoteModel> desktop = ValueNotifier(RemoteModel(connect: false));


  late HistoryTask historyTask;
  late ProxyServer proxyServer;

  /// -画中画
  // bool pictureInPicture = false;

  Future<dynamic> fetchData(String endpoint, Map<String, String> body) async {

    var response = await http.post(Uri.parse(endpoint), body:body);

    if (response.statusCode == 200) {
      return response.body;
    } else {
      throw Exception('Failed to load data');
    }


  }

  // void _showHttpsDialog(BuildContext context) {
  //   showDialog(
  //     context: context,
  //     barrierDismissible: false, // Prevents dismissing dialog when tapping outside
  //     builder: (BuildContext context) {
  //       return AlertDialog(
  //         title: const Text('HTTPS代理教程'),
  //         content: const Text('是否打开 HTTPS代理教程?'),
  //         actions: <Widget>[
  //           TextButton(
  //             child: const Text('取消'),
  //             onPressed: () {
  //               Navigator.of(context).pop();
  //               // Do something when user chooses not to enable HTTPS
  //             },
  //           ),
  //           TextButton(
  //             child: const Text('打开'),
  //             onPressed: () {
  //               Navigator.of(context).pop();
  //               // Do something when user chooses to enable HTTPS
  //               // For example, navigate to MobileSslWidget
  //               navigator(context, MobileSslWidget(proxyServer: proxyServer));
  //             },
  //           ),
  //         ],
  //       );
  //     },
  //   );
  // }

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  @override
  void onUserLeaveHint() {
    enterPictureInPicture();
  }

  Future<bool> enterPictureInPicture() async {
    if (Vpn.isVpnStarted) {
      if (desktop.value.connect || !Platform.isAndroid || !(await (AppConfiguration.instance)).pipEnabled.value) {
        return false;
      }

      return PictureInPicture.enterPictureInPictureMode(
          Platform.isAndroid ? await localIp() : "127.0.0.1", proxyServer.port,
          appList: proxyServer.configuration.appWhitelist, disallowApps: proxyServer.configuration.appBlacklist);
    }
    return false;
  }

  @override
  onPictureInPictureModeChanged(bool isInPictureInPictureMode) async {
    if (isInPictureInPictureMode) {
      Navigator.push(
          context,
          PageRouteBuilder(
              transitionDuration: Duration.zero,
              pageBuilder: (context, animation, secondaryAnimation) {
                return PictureInPictureWindow(container);
              }));
      return;
    }

    if (!isInPictureInPictureMode) {
      Navigator.maybePop(context);
      Vpn.isRunning().then((value) {
        Vpn.isVpnStarted = value;
        SocketLaunch.startStatus.value = ValueWrap.of(value);
      });
    }
  }

  @override
  void onRequest(Channel channel, HttpRequest request) {
    requestStateKey.currentState!.add(channel, request);
    PictureInPicture.addData(request.requestUrl);
  }

  @override
  void onResponse(ChannelContext channelContext, HttpResponse response) {
    requestStateKey.currentState!.addResponse(channelContext, response);
  }

  @override
  void onMessage(Channel channel, HttpMessage message, WebSocketFrame frame) {
    var panel = NetworkTabController.current;
    if (panel?.request.get() == message || panel?.response.get() == message) {
      panel?.changeState();
    }
  }

  @override
  void initState() {
    super.initState();
    AppLifecycleBinding.instance.addListener(this);
    // proxyServer = ProxyServer(widget.configuration);
    proxyServer = widget.proxyServer;
    proxyServer.addListener(this);
    proxyServer.start();


    container = widget.container; // 初始化

    historyTask = HistoryTask.ensureInstance(proxyServer.configuration, container);

    //远程连接
    desktop.addListener(() {
      if (desktop.value.connect) {
        proxyServer.configuration.remoteHost = "http://${desktop.value.host}:${desktop.value.port}";
        checkConnectTask(context);
      } else {
        proxyServer.configuration.remoteHost = null;
      }
    });

    if (widget.appConfiguration.upgradeNoticeV9) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showUpgradeNotice();
      });
    }
  }

  @override
  void didChangeDependencies() {
    // 当State对象依赖的对象发生变化时会被调用。
    // 通常在这个方法中，可以执行一些初始化操作或者处理依赖对象的变化，确保State对象的依赖关系是最新的。
    // 这个方法在State对象第一次构建时也会被调用。

    super.didChangeDependencies();

    final appInfo = Provider.of<AppInfo>(context); // 获取Counter对象


    // 设置Ssl开启状态
    appInfo.setSslStatus(proxyServer.configuration.enableSsl);

    appInfo.setProxyServer(proxyServer);

  }

  @override
  void dispose() {
    desktop.dispose();
    AppLifecycleBinding.instance.removeListener(this);
    super.dispose();
  }

  int exitTime = 0;

  @override
  Widget build(BuildContext context) {
    return PopScope(
        canPop: false,
        onPopInvoked: (d) async {
          if (await enterPictureInPicture()) {
            return;
          }

          if (DateTime.now().millisecondsSinceEpoch - exitTime > 2000) {
            exitTime = DateTime.now().millisecondsSinceEpoch;
            if (mounted) {
              FlutterToastr.show(localizations.appExitTips, this.context,
                  rootNavigator: true, duration: FlutterToastr.lengthLong);
            }
            return;
          }
          //退出程序
          SystemNavigator.pop();
        },
        child: Scaffold(
            floatingActionButton: PictureInPictureIcon(proxyServer),
            body: Scaffold(
              appBar: appBar(),
              drawer: LeftMenuWidget(proxyServer: proxyServer, container: container),
              floatingActionButton: _launchActionButton(),
              body: ValueListenableBuilder(
                  valueListenable: desktop,
                  builder: (context, value, _) {
                    return Column(children: [
                      value.connect ? remoteConnect(value) : const SizedBox(),
                      Expanded(
                          child: RequestListWidget(key: requestStateKey, proxyServer: proxyServer, list: container))
                    ]);
                  }),

            )));
  }

  AppBar appBar() {
    return AppBar(title: MobileSearch(onSearch: (val) => requestStateKey.currentState?.search(val)), actions: [
      IconButton(
          tooltip: localizations.clear,
          icon: const Icon(Icons.cleaning_services_outlined),
          onPressed: () => requestStateKey.currentState?.clean()),
      const SizedBox(width: 2),
      MoreMenu(proxyServer: proxyServer, desktop: desktop),
      const SizedBox(width: 10),
    ]);
  }

  FloatingActionButton _launchActionButton() {
    final appInfo = Provider.of<AppInfo>(context); // 获取Counter对象
    bool serverLaunch = appInfo.serverLaunch;
    bool serverInitRun = appInfo.serverInitRun;

    print('_launchActionButton------------------------------');
    print(serverLaunch);

    return FloatingActionButton(
      onPressed: null,
      backgroundColor: const Color(0xffeaeaea),
      child: Center(
          child: SocketLaunch(
              proxyServer: proxyServer,
              size: 36,
              startup: proxyServer.configuration.startup,
              serverLaunch: serverLaunch,
              serverInitRun: serverInitRun,
              onStart: () async {
                Vpn.startVpn(
                    Platform.isAndroid ? await localIp() : "127.0.0.1", proxyServer.port, proxyServer.configuration);
              },
              onStop: () => Vpn.stopVpn())),
    );
  }

  showUpgradeNotice() {
    bool isCN = Localizations.localeOf(context) == const Locale.fromSubtags(languageCode: 'zh');

    String content = isCN
        ? '提示：默认不会开启HTTPS抓包，请安装证书后再开启HTTPS抓包。\n\n'
            '1. 展示请求发起的应用图标；\n'
            '2. 关键词匹配高亮；\n'
            '3. 脚本批量操作和导入导出；\n'
            '4. 脚本支持日志查看，通过console.log()输出；\n'
            '5. 设置增加自动开启抓包；\n'
            '6. Android证书下载优化；'
        : 'Tips：By default, HTTPS packet capture will not be enabled. Please install the certificate before enabling HTTPS packet capture。\n\n'
            'Click HTTPS Capture packets(Lock icon)，Choose to install the root certificate and follow the prompts to proceed。\n\n'
            '1. Display the application icon initiated by the request；\n'
            '2. Keyword matching highlights;\n'
            '3. Script batch operations and import/export;\n'
            '4. The script supports log viewing, output through console.log()；\n'
            '5. Setting Auto Start Recording Traffic；\n'
            '6. Android certificate download optimization; \n';
    showAlertDialog(isCN ? '更新内容V1.0.9' : "Update content V1.0.9", content, () {
      widget.appConfiguration.upgradeNoticeV9 = false;
      widget.appConfiguration.flushConfig();
    });
  }

  /// - 远程连接
  Widget remoteConnect(RemoteModel value) {
    return Container(
        margin: const EdgeInsets.only(top: 0, bottom: 0),
        height: 55,
        width: double.infinity,
        child: ElevatedButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (BuildContext context) {
            return ConnectRemote(desktop: desktop, proxyServer: proxyServer);
          })),
          child: Text(localizations.remoteConnected(desktop.value.os ?? ''),
              style: Theme.of(context).textTheme.titleMedium),
        ));
  }

  showAlertDialog(String title, String content, Function onClose) {
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) {
          return AlertDialog(
              scrollable: true,
              actions: [
                TextButton(
                    onPressed: () {
                      onClose.call();
                      Navigator.pop(context);
                    },
                    child: Text(localizations.cancel))
              ],
              title: Text(title, style: const TextStyle(fontSize: 18)),
              content: Text(content));
        });
  }

  /// - 检查远程连接
  checkConnectTask(BuildContext context) async {
    int retry = 0;
    Timer.periodic(const Duration(milliseconds: 3000), (timer) async {
      if (desktop.value.connect == false) {
        timer.cancel();
        return;
      }

      try {
        var response = await HttpClients.get("http://${desktop.value.host}:${desktop.value.port}/ping")
            .timeout(const Duration(seconds: 1));
        if (response.bodyAsString == "pong") {
          retry = 0;
          return;
        }
      } catch (e) {
        retry++;
      }

      if (retry > 5) {
        timer.cancel();
        desktop.value = RemoteModel(connect: false);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(localizations.remoteConnectDisconnect),
              action: SnackBarAction(
                  label: localizations.reconnect, onPressed: () => desktop.value = RemoteModel(connect: true))));
        }
      }
    });
  }
}
