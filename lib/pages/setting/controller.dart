import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hikari_novel_flutter/models/common/language.dart';
import 'package:hikari_novel_flutter/models/common/wenku8_node.dart';

import '../../service/local_storage_service.dart';
import '../../network/request.dart';

class SettingController extends GetxController {
  RxBool isAutoCheckUpdate = LocalStorageService.instance
      .getIsAutoCheckUpdate()
      .obs;
  Rx<Language> language = Rx(LocalStorageService.instance.getLanguage());
  RxBool isRelativeTime = LocalStorageService.instance.getIsRelativeTime().obs;
  Rx<Wenku8Node> wenku8Node = Rx(LocalStorageService.instance.getWenku8Node());
  Rx<ThemeMode> themeMode = Rx(LocalStorageService.instance.getThemeMode());
  RxBool isDynamicColor = LocalStorageService.instance.getIsDynamicColor().obs;
  Rx<Color> customColor = Rx(LocalStorageService.instance.getCustomColor());
  RxBool isUseFlareSolverr = LocalStorageService.instance
      .getUseFlareSolverr()
      .obs;
  RxString flareSolverrUrl = LocalStorageService.instance
      .getFlareSolverrUrl()
      .obs;
  RxString flareSolverrSessionId = LocalStorageService.instance
      .getFlareSolverrSessionId()
      .obs;
  void changeIsAutoCheckUpdate(bool enabled) {
    isAutoCheckUpdate.value = enabled;
    LocalStorageService.instance.setIsAutoCheckUpdate(enabled);
  }

  void changeIsRelativeTime(bool enabled) {
    isRelativeTime.value = enabled;
    LocalStorageService.instance.setIsRelativeTime(enabled);
  }

  void changeLanguage(Language l) async {
    switch (l) {
      case Language.simplifiedChinese:
        Get.updateLocale(Locale("zh", "CN"));
      case Language.traditionalChinese:
        Get.updateLocale(Locale("zh", "TW"));
      case Language.followSystem:
        {
          if (Get.deviceLocale! != Locale("zh", "CN") &&
              Get.deviceLocale! != Locale("zh", "CN")) {
            Get.updateLocale(Locale("zh", "CN"));
          } else {
            Get.updateLocale(Get.deviceLocale!);
          }
        }
    }
    language.value = l;
    LocalStorageService.instance.setLanguage(l);
  }

  void changeWenku8Node(Wenku8Node n) {
    wenku8Node.value = n;
    LocalStorageService.instance.setWenku8Node(n);
  }

  void changeCustomColor(Color color) {
    customColor.value = color;
    LocalStorageService.instance.setCustomColor(color);
    Get.forceAppUpdate();
  }

  void changeIsDynamicColor(bool enabled) {
    isDynamicColor.value = enabled;
    LocalStorageService.instance.setIsDynamicColor(enabled);
    Get.forceAppUpdate();
  }

  void changeThemeMode(ThemeMode mode) {
    themeMode.value = mode;
    LocalStorageService.instance.setThemeMode(mode);
    Get.forceAppUpdate();
  }

  void changeUseFlareSolverr(bool enabled) {
    isUseFlareSolverr.value = enabled;
    LocalStorageService.instance.setUseFlareSolverr(enabled);
    Get.forceAppUpdate();
  }

  Future<void> editFlareSolverrUrl(BuildContext context) async {
    final TextEditingController textController = TextEditingController(
      text: LocalStorageService.instance.getFlareSolverrUrl(),
    );

    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Configure FlareSolverr"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Enter the full API URL (e.g. http://192.168.1.5:8191/v1)",
              ),
              TextField(controller: textController),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () async {
                final url = textController.text;
                await LocalStorageService.instance.setFlareSolverrUrl(url);
                Navigator.pop(context, url);
              },
              child: const Text("Save"),
            ),
          ],
        );
      },
    );

    if (result != null) {
      flareSolverrUrl.value = result;
    }
  }

  Future<void> editFlareSolverrSessionId(BuildContext context) async {
    final TextEditingController textController = TextEditingController(
      text: LocalStorageService.instance.getFlareSolverrSessionId(),
    );

    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("FlareSolverr Session ID"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Enter a session ID to reuse a persistent FlareSolverr session (leave empty for temporary sessions).",
              ),
              TextField(controller: textController),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () async {
                final id = textController.text;
                await LocalStorageService.instance.setFlareSolverrSessionId(id);
                Navigator.pop(context, id);
              },
              child: const Text("Save"),
            ),
          ],
        );
      },
    );

    if (result != null) {
      flareSolverrSessionId.value = result;
    }
  }

  Future<void> destroyFlareSolverrSession(BuildContext context) async {
    final id = flareSolverrSessionId.value;
    if (id.trim().isEmpty) {
      Get.snackbar('Error', 'No session ID configured');
      return;
    }
    try {
      await Request.destroyFlareSession(id);
      Get.snackbar('Success', 'Session destroyed');
    } catch (e) {
      Get.snackbar('Error', 'Failed to destroy session: $e');
    }
  }
}
