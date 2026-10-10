import 'package:flutter/material.dart';

void main() {
  runApp(const SilentQueueApp());
}

class SilentQueueApp extends StatelessWidget {
  const SilentQueueApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SilentQueue',
      theme: ThemeData(
        fontFamily: 'Roboto', // Make sure to add custom font if needed
        scaffoldBackgroundColor: const Color(0xFFA5B8AD), // Outer border color
      ),
      home: const FrameWrapper(),
    );
  }
}

class FrameWrapper extends StatelessWidget {
  const FrameWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Container(
          width: 380,
          height: 760,
          decoration: BoxDecoration(
            color: const Color(0xFFF7FBF9), // Light background color from image
            border: Border.all(color: Colors.black87, width: 1.5),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const ClipRRect(
            borderRadius: BorderRadius.all(Radius.circular(2)),
            child: HomeScreen(),
          ),
        ),
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7FBF9),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          child: Column(
            children: [
              // Header Section
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  RichText(
                    text: const TextSpan(
                      children: [
                        TextSpan(
                          text: 'silent',
                          style: TextStyle(
                            color: Colors.black,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            letterSpacing: -0.5,
                          ),
                        ),
                        TextSpan(
                          text: 'Queue',
                          style: TextStyle(
                            color: Color(0xFF13CA6D),
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Live Badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD6F9E8),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(
                          Icons.circle,
                          size: 8,
                          color: Color(0xFF13CA6D),
                        ),
                        SizedBox(width: 6),
                        Text(
                          'Live',
                          style: TextStyle(
                            color: Color(0xFF117548),
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const Spacer(),

              // Concentric Circles with Token ID
              Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 280,
                    height: 280,
                    decoration: const BoxDecoration(
                      color: Color(0xFFE3F6EE),
                      shape: BoxShape.circle,
                    ),
                  ),
                  Container(
                    width: 220,
                    height: 220,
                    decoration: const BoxDecoration(
                      color: Color(0xFFC7F1E0),
                      shape: BoxShape.circle,
                    ),
                  ),
                  Container(
                    width: 160,
                    height: 160,
                    decoration: const BoxDecoration(
                      color: Color(0xFFA5EAD0),
                      shape: BoxShape.circle,
                    ),
                  ),
                  Container(
                    width: 110,
                    height: 110,
                    decoration: const BoxDecoration(
                      color: Color(0xFF0F766E), // Inner dark teal circle
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      'A102',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ),

              const Spacer(),

              // Text Content
              const Text(
                'Your time is yours.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Join a queue and step away.\nWe\'ll tell you when it\'s time to return.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: Color(0xFF6B7280),
                  height: 1.3,
                ),
              ),

              const Spacer(),

              // Join Queue Button
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0F766E),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: () {
                    // Navigation to Next Screen
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const QueueJoinedScreen(),
                      ),
                    );
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Text(
                        'Join a Queue',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(width: 10),
                      Icon(
                        Icons.arrow_forward_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // Footer Note
              const Text(
                'No smartphone? That\'s okay.\nYour physical token still works.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF8E95A2),
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

// Destination Screen after clicking "Join a Queue"
class QueueJoinedScreen extends StatelessWidget {
  const QueueJoinedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7FBF9),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black),
        title: const Text(
          'Queue Status',
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
        ),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.check_circle_outline_rounded,
              size: 80,
              color: Color(0xFF0F766E),
            ),
            const SizedBox(height: 20),
            const Text(
              ' You are in the queue!',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            const Text(
              'Your position is saved. We will notify you.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 30),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0F766E),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () => Navigator.pop(context),
              child: const Text('Go Back', style: TextStyle(color: Colors.white)),
            )
          ],
        ),
      ),
    );
  }
}