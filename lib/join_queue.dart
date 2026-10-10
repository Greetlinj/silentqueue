import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'enter_pin_screen.dart';
import 'tokenverified.dart';

class JoinQueueScreen extends StatefulWidget {
  const JoinQueueScreen({super.key});

  @override
  State<JoinQueueScreen> createState() => _JoinQueueScreenState();
}

class _JoinQueueScreenState extends State<JoinQueueScreen> {
  final MobileScannerController scannerController = MobileScannerController();
  bool isScanned = false;

  @override
  void dispose() {
    scannerController.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (!isScanned) {
      final List<Barcode> barcodes = capture.barcodes;
      for (final barcode in barcodes) {
        if (barcode.rawValue != null) {
          setState(() {
            isScanned = true;
          });

          String assignedToken = "A104";
          int peopleInLine = 3;

          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => TokenVerifiedScreen(
                tokenNumber: assignedToken,
                peopleAhead: peopleInLine,
              ),
            ),
          );
          break;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7FBF9),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          child: Column(
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: const Icon(Icons.arrow_back, color: Colors.black, size: 28),
                    onPressed: () => Navigator.pop(context),
                  ),
                  RichText(
                    text: const TextSpan(
                      children: [
                        TextSpan(
                          text: 'silent',
                          style: TextStyle(
                            color: Colors.black,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        TextSpan(
                          text: 'Queue',
                          style: TextStyle(
                            color: Color(0xFF13CA6D),
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD6F9E8),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.circle, size: 8, color: Color(0xFF13CA6D)),
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

              const SizedBox(height: 32),

              const Text(
                'JOIN A QUEUE',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                  color: Colors.black,
                ),
              ),

              const SizedBox(height: 28),

              // Live QR Scanner View
              Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  color: const Color(0xFFE5F7F0),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: MobileScanner(
                    controller: scannerController,
                    onDetect: _onDetect,
                  ),
                ),
              ),

              const SizedBox(height: 24),

              const Text(
                'Scan the QR code provided at the location.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: Color(0xFF374151),
                ),
              ),

              const Spacer(),

              // Already Have Token Container
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFFD3F8E9),
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.black, width: 2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.close, size: 18, color: Colors.black),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Already have token?',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: Colors.black,
                            ),
                          ),
                          GestureDetector(
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => const EnterPinScreen(),
                                ),
                              );
                            },
                            child: const Text(
                              'ENTER PIN →',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1F2937),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  ],
                ),
              ),

              const SizedBox(height: 28),

              const Text(
                'No SmartPhone?',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Ask staff for a physical token',
                style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF4B5563),
                ),
              ),

              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}