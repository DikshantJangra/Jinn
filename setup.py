from setuptools import setup, find_packages

setup(
    name="jinn",
    version="1.0.0",
    description="Autonomous Local AI Application Powered by Google Gemma",
    author="Dikshant Jangra, Somraj, Ritesh",
    packages=find_packages(),
    python_requires=">=3.9",
    install_requires=[
        "requests>=2.31.0",
    ],
    entry_points={
        "console_scripts": [
            "jinn=jinn.cli:main",
        ],
    },
)
