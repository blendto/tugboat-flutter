import 'package:flutter/material.dart';
import 'package:tugboat/tugboat.dart';

import '../widgets/demo_widgets.dart';

/// Manual scroll-attribution playground for simulator verification.
class ScrollPlaygroundScreen extends StatelessWidget {
  const ScrollPlaygroundScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scroll playground')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Try scrolling each section. Dead swipes on the static image should '
            'emit swipe events with scrolled:false.',
          ),
          const SizedBox(height: 16),
          DemoSection(
            title: 'Long vertical feed',
            children: [
              TugboatSubView(
                label: 'vertical-feed',
                child: SizedBox(
                  height: 220,
                  child: ListView.builder(
                    itemCount: 30,
                    itemBuilder: (context, index) =>
                        ListTile(title: Text('Feed row $index')),
                  ),
                ),
              ),
            ],
          ),
          DemoSection(
            title: 'Nested horizontal carousel',
            children: [
              TugboatSubView(
                label: 'carousel',
                child: SizedBox(
                  height: 120,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: 12,
                    itemBuilder: (context, index) => Container(
                      width: 140,
                      margin: const EdgeInsets.only(right: 8),
                      color: Colors.primaries[index % Colors.primaries.length],
                      alignment: Alignment.center,
                      child: Text('Card $index'),
                    ),
                  ),
                ),
              ),
            ],
          ),
          DemoSection(
            title: 'Static image (dead swipe target)',
            children: [
              TugboatSubView(
                label: 'hero-image',
                child: Container(
                  height: 180,
                  decoration: BoxDecoration(
                    color: Colors.blueGrey.shade200,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.image_outlined, size: 64),
                ),
              ),
            ],
          ),
          DemoSection(
            title: 'Tab pages',
            children: [
              SizedBox(
                height: 180,
                child: PageView(
                  children: const [
                    ColoredBox(color: Colors.red),
                    ColoredBox(color: Colors.green),
                    ColoredBox(color: Colors.blue),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
