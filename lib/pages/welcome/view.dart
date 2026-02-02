import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hikari_novel_flutter/router/route_path.dart';
import 'package:hikari_novel_flutter/widgets/state_page.dart';
// navigation via top-level routes; AppSubRouter not needed here

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const LogoPage(),
            const SizedBox(height: 20),
            Text(
              "welcome_to_use_app".tr,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            Text("welcome_tip".tr, style: TextStyle(fontSize: 14)),
            const SizedBox(height: 20),
            TextButton.icon(
              onPressed: () => Get.toNamed(RoutePath.login),
              label: Text("go_to_login".tr),
              icon: const Icon(Icons.login),
            ),
            TextButton.icon(
              onPressed: () => Get.toNamed(RoutePath.setting),
              label: Text("go_to_setting".tr),
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
      ),
    );
  }
}
