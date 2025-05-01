import numpy as np
from scipy.io import wavfile
import random

# Parameters
sample_rate = 22050  # Hz
bit_duration = 0.02  # Duration per bit (s)
amplitude = 0.1
frequency_0 = 1000  # Frequency for binary 0 (Hz)
frequency_1 = 1500  # Frequency for binary 1 (Hz)
noise_range = (-0.05, 0.05)

# Function to convert text to binary
def text_to_binary(text):
    binary = ''.join(format(ord(char), '08b') for char in text)
    return binary

# Function to generate audio signal for a binary string
def generate_encoded_sound(binary):
    samples_per_bit = int(bit_duration * sample_rate)
    total_samples = len(binary) * samples_per_bit
    samples = np.zeros(total_samples, dtype=np.float32)
    
    current_sample = 0
    for bit in binary:
        frequency = frequency_1 if bit == '1' else frequency_0
        for i in range(samples_per_bit):
            t = current_sample / sample_rate
            noise = random.uniform(noise_range[0], noise_range[1])
            sample_value = np.sin(2 * np.pi * frequency * t) * amplitude + noise
            samples[current_sample] = sample_value
            current_sample += 1
    
    return samples

# Main function to encode text and save to WAV
def create_text_encoded_audio(text, filename):
    # Convert text to binary
    binary = text_to_binary(text)
    print(f"Text: {text}")
    print(f"Binary: {binary}")
    
    # Generate audio
    samples = generate_encoded_sound(binary)
    
    # Save to WAV file
    wavfile.write(filename, sample_rate, samples)
    print(f"Saved audio to {filename}")

# Example usage
text_to_encode = "Lutheran Radio"  # Define the text to embed
filename = "special_tuning_sound.wav"
create_text_encoded_audio(text_to_encode, filename)
