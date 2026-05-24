import 'package:flutter/material.dart';

/// Material 规范：最短边 ≥ 600dp 视为平板布局，否则为手机。
const double kTabletShortestSideDp = 600;

bool isTabletLayout(BuildContext context) {
  return MediaQuery.sizeOf(context).shortestSide >= kTabletShortestSideDp;
}

/// 平板仅电容笔书写；手机允许手指与电容笔。
bool handCanvasStylusOnly(BuildContext context) => isTabletLayout(context);
