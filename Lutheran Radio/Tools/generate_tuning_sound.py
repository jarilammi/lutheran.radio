import numpy as np
from scipy.io import wavfile
import random

# Parameters
sample_rate = 22050
duration = 0.5
total_samples = int(duration * sample_rate)
segment_duration = 0.012
samples_per_segment = int(segment_duration * sample_rate)
total_segments = total_samples // samples_per_segment
remaining_samples = total_samples % samples_per_segment
amplitude = 0.1
frequency_range = (500, 1500)
noise_range = (-0.05, 0.05)

# Function to generate a single tuning sound
def generate_tuning_sound():
    samples = np.zeros(total_samples, dtype=np.float32)
    current_sample = 0
    for segment in range(total_segments):
        frequency = random.uniform(frequency_range[0], frequency_range[1])
        for i in range(samples_per_segment):
            t = current_sample / sample_rate
            noise = random.uniform(noise_range[0], noise_range[1])
            sample_value = np.sin(2 * np.pi * frequency * t) * amplitude + noise
            samples[current_sample] = sample_value
            current_sample += 1
    # Remaining samples
    if remaining_samples > 0:
        frequency = random.uniform(frequency_range[0], frequency_range[1])
        for i in range(remaining_samples):
            t = current_sample / sample_rate
            noise = random.uniform(noise_range[0], noise_range[1])
            sample_value = np.sin(2 * np.pi * frequency * t) * amplitude + noise
            samples[current_sample] = sample_value
            current_sample += 1
    return samples

# Generate multiple files
for file_num in range(1, 4):  # Generate 3 files
    samples = generate_tuning_sound()
    wavfile.write(f'tuning_sound_{file_num}.wav', sample_rate, samples)
