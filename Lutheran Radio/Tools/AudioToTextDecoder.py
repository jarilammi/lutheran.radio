import numpy as np
from scipy.io import wavfile
from scipy.fft import fft

# Parameters (must match encoding)
sample_rate = 22050
bit_duration = 0.02
frequency_0 = 1000
frequency_1 = 1500
samples_per_bit = int(bit_duration * sample_rate)

# Function to decode binary from audio
def decode_audio_to_binary(samples):
    binary = ""
    num_bits = len(samples) // samples_per_bit
    
    for i in range(num_bits):
        segment = samples[i * samples_per_bit:(i + 1) * samples_per_bit]
        # Compute FFT to find dominant frequency
        freqs = np.fft.fftfreq(len(segment), 1 / sample_rate)
        fft_vals = np.abs(fft(segment))
        dominant_freq = abs(freqs[np.argmax(fft_vals)])
        # Classify frequency
        if abs(dominant_freq - frequency_1) < abs(dominant_freq - frequency_0):
            binary += '1'
        else:
            binary += '0'
    
    return binary

# Function to convert binary to text
def binary_to_text(binary):
    text = ""
    for i in range(0, len(binary), 8):
        byte = binary[i:i+8]
        if len(byte) == 8:
            text += chr(int(byte, 2))
    return text

# Main decoding function
def decode_audio_file(filename):
    rate, samples = wavfile.read(filename)
    if len(samples.shape) > 1:
        samples = samples[:, 0]  # Use one channel if stereo
    binary = decode_audio_to_binary(samples)
    text = binary_to_text(binary)
    print(f"Decoded binary: {binary}")
    print(f"Decoded text: {text}")

# Example usage
decode_audio_file("special_tuning_sound.wav")
